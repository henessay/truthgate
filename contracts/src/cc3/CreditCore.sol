// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {TruthGateBase} from "./TruthGateBase.sol";
import {LPPool} from "./LPPool.sol";
import {RocketPoolParser} from "./parsers/RocketPoolParser.sol";
import {EigenLayerParser} from "./parsers/EigenLayerParser.sol";

/// @title CreditCore
/// @notice TruthGate credit core on CC3. Scoring grows ONLY from proven Sepolia
/// events (via TruthGateBase.execute), loans are issued from LPPool in native
/// CTC, repayment is path A (CTC directly here) or path B (wUSDC into the
/// RepaymentBridge treasury; only accounting happens here).
contract CreditCore is TruthGateBase {
    // ---------- Actions (scoring, arrive via execute) ----------
    enum ScoreActions {
        ScoreDeposit, // 0: deposit into the vault on Sepolia
        ScoreRepayment, // 1: loan repayment on Sepolia
        ScoreLiquidation, // 2: borrower liquidated on Sepolia (negative signal)
        ScoreRocketPoolDeposit, // 3: proven Rocket Pool ETH deposit (CAPITAL)
        ScoreEigenDeposit // 4: proven EigenLayer restake (CAPITAL, flat per event)
    }
    error InvalidAction(uint8 action);

    // ---------- Signatures of consumed Sepolia events ----------
    // keccak256("FundsDeposited(address,uint256,uint256)")
    // event: FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce)
    bytes32 public constant DEPOSIT_EVENT_SIGNATURE =
        0xbee4fe3675934fca827426c793623996a3079255089bda3a717019ffc5db2765;

    // keccak256("LoanRepaidOnEth(address,uint256,uint256)")
    // event: LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount)
    bytes32 public constant REPAY_EVENT_SIGNATURE =
        0x9d2dba8b6b5cbf171f55f328240634b55005b55f505bfe0ac482893b92d0fd88;

    // keccak256("LiquidationCall(address,address,address,uint256,uint256,address,bool)")
    // Aave v3 Pool event, byte-for-byte: LiquidationCall(address indexed collateralAsset,
    // address indexed debtAsset, address indexed user, uint256 debtToCover,
    // uint256 liquidatedCollateralAmount, address liquidator, bool receiveAToken).
    // The layout is deliberately Aave's real one (not a custom event) so the parser has
    // a single implementation valid against both the simulator and a real Aave deployment.
    bytes32 public constant LIQUIDATION_EVENT_SIGNATURE =
        0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286;

    // ---------- Lending parameters (v1: fixed constants) ----------
    /// @notice Fixed v1 rate: 500 = 5% for the loan term.
    uint256 public constant INTEREST_RATE_BPS = 500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @notice Production loan term in CC3 blocks (~17 days at 15 s/block) —
    /// constructor default (0 passed → this value is used).
    uint256 public constant DEFAULT_LOAN_DURATION_BLOCKS = 100_000;
    /// @notice Production minimum hold period for localScore: a quarter of the term.
    uint256 public constant DEFAULT_MIN_HOLD_BLOCKS = DEFAULT_LOAN_DURATION_BLOCKS / 4;
    /// @notice Loan term in CC3 blocks (path A deadline). Constructor parameter:
    /// the demo deployment compresses it (~240 blocks ≈ 1 hour) so the full
    /// "borrow → hold → repay → limit grows" cycle is observable; the localScore
    /// formula's economics is unchanged by compression (the award depends on the
    /// FRACTION of the term held — see the similarity test
    /// test_scoreScaleInvariantUnderCompressedSchedule).
    uint256 public immutable LOAN_DURATION_BLOCKS;
    /// @notice Max open loans per borrower (bounds the overdue-check loop).
    uint256 public constant MAX_OPEN_LOANS = 8;

    // Piecewise-linear credit limit formula:
    //   ethScore < MIN_ETH_SCORE                 → limit 0
    //   else base = BASE_LIMIT + (ethScore - MIN_ETH_SCORE) * SCORE_SLOPE_NUM / SCORE_SLOPE_DEN,
    //   base is capped at MAX_BASE_LIMIT; total = base + localScore * LOCAL_SCORE_K.
    /// @notice Minimum ethScore (in wei of Sepolia deposits) to access credit.
    uint256 public constant MIN_ETH_SCORE = 1e16; // 0.01 ETH
    /// @notice The first credit limit is small: a base of 5 CTC at the MIN_ETH_SCORE threshold.
    uint256 public constant BASE_LIMIT = 5 ether;
    /// @notice +10 CTC of limit per 1 ETH of score above the threshold (10 wei CTC per 1 wei score).
    uint256 public constant SCORE_SLOPE_NUM = 10;
    uint256 public constant SCORE_SLOPE_DEN = 1;
    uint256 public constant MAX_BASE_LIMIT = 500 ether;
    /// @notice Limit bonus: +1 CTC per unit of localScore (unit = 1e18, see Borrower.localScore).
    uint256 public constant LOCAL_SCORE_K = 1 ether;
    /// @notice localScore normalization principal: holding this principal for the
    /// full term yields exactly one localScore unit (= +LOCAL_SCORE_K to the limit).
    /// 4.5 CTC is the midpoint of a typical demo-scale loan (4–5 CTC), so the limit
    /// gain for a "normal" repaid loan matches the previous "+1 per repayment" model.
    uint256 public constant LOCAL_SCORE_NORM_PRINCIPAL = 4.5 ether;
    /// @notice Minimum loan hold period for localScore accrual (in CC3 blocks).
    /// A quarter of the term: any shorter and the payment-discipline signal is
    /// indistinguishable from score farming via instant cycles; repaying before the
    /// threshold works normally (principal + interest) but does not grow the score.
    /// Constructor parameter (0 → production default).
    uint256 public immutable MIN_HOLD_BLOCKS;
    /// @notice Penalty on the interest part for an overdue repayment: +50%.
    uint256 public constant LATE_PENALTY_BPS = 5000;
    /// @notice Cap on the total DEPOSIT contribution to ethScore per borrower. Deposits
    /// are a weak signal (farmable by circulating the same funds deposit→withdraw→deposit),
    /// so they are capped; repayments carry the main score weight. Demo scale: two average
    /// 1 ETH deposits; above the cap a deposit is still verified and emits the event,
    /// but does not grow the score.
    uint256 public constant DEPOSIT_SCORE_CAP = 2 ether;
    /// @notice Flat CAPITAL credit per proven EigenLayer deposit. Flat, not
    /// share-proportional: strategy shares are units of arbitrary LSTs —
    /// heterogeneous across strategies and not 1:1 with ETH — so per the bureau's
    /// design rule the amount never enters the formula (it is emitted only).
    /// Draws from the same joint CAPITAL cap as ETH deposits (see depositScoreOf).
    uint256 public constant EIGEN_DEPOSIT_FLAT_SCORE = 0.1 ether;
    /// @notice Flat bonus per proven repayment act on Sepolia: the frequency of
    /// payment discipline carries its own weight, not just the volume.
    uint256 public constant FLAT_REPAYMENT_BONUS = 0.1 ether;
    /// @notice Credit-limit penalty for the FIRST proven liquidation of a borrower.
    /// The penalty is per-event, NOT amount-proportional: debtToCover is denominated
    /// in an arbitrary reserve token (500 USDC at 6 decimals vs 500 DAI at 18
    /// decimals differ by 1e12), so amounts from heterogeneous assets cannot be
    /// compared trustlessly without price oracles. The amount is still parsed and
    /// emitted for transparency — it just never enters the formula.
    uint256 public constant LIQUIDATION_PENALTY_FIRST = 1 ether;
    /// @notice Penalty for each SUBSEQUENT proven liquidation: repeat offenses
    /// escalate (1 CTC, then 2 CTC each).
    uint256 public constant LIQUIDATION_PENALTY_REPEAT = 2 ether;
    /// @notice Cap on the TOTAL accumulated liquidation penalty per borrower.
    /// Together with the creditLimit clamp (the penalty burns only the earned bonus,
    /// BASE_LIMIT survives), this guarantees third-party liquidation proofs degrade
    /// but never weaponize into a full lockout.
    uint256 public constant LIQUIDATION_PENALTY_CAP = 5 ether;

    // ---------- Loan state machine (USCLoanManager fork) ----------
    enum LoanStatus {
        None, // 0 — slot unused; explicit guard against "zero loan looks like Created"
        Created,
        Funded,
        PartlyRepaid,
        Repaid,
        Expired
    }

    struct Loan {
        address borrower;
        uint256 principal;
        uint256 interestDue; // fixed at issuance: principal * INTEREST_RATE_BPS / 10000
        uint256 repaidAmount; // accumulated across both paths
        uint256 usdcRepaidShare; // share repaid via path B (~30% cap enforced by RepaymentBridge)
        uint256 deadlineBlock; // path A deadline in CC3 blocks
        LoanStatus status;
        // How much of repaidAmount is attributed to principal. Path A repays principal
        // first (hard CTC restores the pool's principal), path B repays interest first
        // (the SwapDesk discount falls on the interest margin, not the principal).
        // Field appended at the end of the struct to keep positions in the existing
        // getter tuple unchanged.
        uint256 principalRepaid;
    }

    struct Borrower {
        uint256 ethScore; // grows ONLY from proven Sepolia events
        // Grows for repaid loans on CC3 in proportion to the risk taken:
        // principal × heldBlocks / LOAN_DURATION_BLOCKS (see _localScoreDelta).
        // Units: 1e18 = one score unit (= +LOCAL_SCORE_K to the limit).
        uint256 localScore;
        uint256 openDebt; // total outstanding debt (principal + interest)
        uint256 loansCompleted;
        // Accumulated credit-limit reduction from proven liquidations (wei of CTC limit).
        // Applied in creditLimit() against the earned bonus only — never against
        // BASE_LIMIT. Field appended at the end of the struct to keep positions in
        // the existing getter tuple unchanged.
        uint256 liquidationPenalty;
    }

    LPPool public immutable POOL;

    address public vaultOnSepolia; // source of FundsDeposited
    address public loanBookOnSepolia; // source of LoanRepaidOnEth
    // CAPITAL sources beyond the vault (owner-registered when their chain is
    // attested; unset ⇒ the action reverts):
    address public rocketDepositPoolSource; // source of DepositReceived (upgradeable via RocketStorage)
    address public eigenStrategyManagerSource; // source of EigenLayer Deposit
    address public repaymentBridge; // the only caller allowed to invoke path B

    mapping(uint256 => Loan) public loans;
    mapping(address => Borrower) public borrowers;
    mapping(address => uint256[]) internal _openLoans;
    /// @notice JOINT capital accumulator: how much ethScore the address has earned
    /// across ALL proven CAPITAL sources (vault deposits, Rocket Pool deposits,
    /// EigenLayer restakes), for the shared DEPOSIT_SCORE_CAP. One cap on purpose —
    /// the double-counting guard: the same capital moved between protocols (or an
    /// LST restaked on top of a stake) is counted once, not once per protocol.
    mapping(address => uint256) public depositScoreOf;

    uint256 public nextLoanId = 1;

    event EthScoreIncreased(address indexed borrower, uint256 delta, bytes32 indexed queryId);
    /// @dev debtToCover is emitted for transparency only — it does not affect the
    /// penalty (heterogeneous reserve-token amounts are not comparable on-chain).
    event LiquidationPenaltyApplied(
        address indexed borrower, uint256 penalty, uint256 debtToCover, bytes32 indexed queryId
    );
    event LoanOpened(
        uint256 indexed loanId, address indexed borrower, uint256 principal, uint256 interestDue, uint256 deadlineBlock
    );
    event LoanPartiallyRepaid(uint256 indexed loanId, uint256 amount, bool viaBridge);
    event LoanRepaid(uint256 indexed loanId);
    event LoanExpired(uint256 indexed loanId);
    event VaultOnSepoliaRegistered(address indexed vault);
    event LoanBookOnSepoliaRegistered(address indexed loanBook);
    event RocketDepositPoolRegistered(address indexed depositPool);
    event EigenStrategyManagerRegistered(address indexed strategyManager);
    event RepaymentBridgeSet(address indexed bridge);

    modifier onlyRepaymentBridge() {
        require(msg.sender == repaymentBridge, "not RepaymentBridge");
        _;
    }

    /// @param loanDurationBlocks_ 0 → DEFAULT_LOAN_DURATION_BLOCKS (production); demo ~240.
    /// @param minHoldBlocks_ 0 → DEFAULT_MIN_HOLD_BLOCKS (production); demo ~60.
    /// The 0 sentinel means "default threshold": deploying with a literally zero
    /// MIN_HOLD (score for instant repayment) is impossible — and unnecessary.
    constructor(address payable pool_, uint256 loanDurationBlocks_, uint256 minHoldBlocks_) {
        require(pool_ != address(0), "zero pool");
        POOL = LPPool(pool_);

        LOAN_DURATION_BLOCKS = loanDurationBlocks_ == 0 ? DEFAULT_LOAN_DURATION_BLOCKS : loanDurationBlocks_;
        MIN_HOLD_BLOCKS = minHoldBlocks_ == 0 ? DEFAULT_MIN_HOLD_BLOCKS : minHoldBlocks_;
        require(MIN_HOLD_BLOCKS <= LOAN_DURATION_BLOCKS, "min hold exceeds duration");
    }

    // ---------- Registration of sources and the bridge ----------

    function registerVaultOnSepolia(address vault) external onlyOwner {
        require(vault != address(0), "zero vault");
        vaultOnSepolia = vault;
        emit VaultOnSepoliaRegistered(vault);
    }

    function registerLoanBookOnSepolia(address loanBook) external onlyOwner {
        require(loanBook != address(0), "zero loan book");
        loanBookOnSepolia = loanBook;
        emit LoanBookOnSepoliaRegistered(loanBook);
    }

    function registerRocketDepositPool(address depositPool) external onlyOwner {
        require(depositPool != address(0), "zero deposit pool");
        rocketDepositPoolSource = depositPool;
        emit RocketDepositPoolRegistered(depositPool);
    }

    function registerEigenStrategyManager(address strategyManager) external onlyOwner {
        require(strategyManager != address(0), "zero strategy manager");
        eigenStrategyManagerSource = strategyManager;
        emit EigenStrategyManagerRegistered(strategyManager);
    }

    function setRepaymentBridge(address bridge) external onlyOwner {
        require(bridge != address(0), "zero bridge");
        repaymentBridge = bridge;
        emit RepaymentBridgeSet(bridge);
    }

    // ---------- Scoring: intake of proven Sepolia events ----------

    // The freshness window (minAcceptedHeight) applies to scoring actions.
    // Path B repayments never arrive via execute at all (their proofs are handled
    // by RepaymentBridge), so all actions here are scoring actions.
    function _isFreshnessEnforced(uint8 action) internal pure override returns (bool) {
        return action == uint8(ScoreActions.ScoreDeposit) || action == uint8(ScoreActions.ScoreRepayment)
            || action == uint8(ScoreActions.ScoreLiquidation)
            || action == uint8(ScoreActions.ScoreRocketPoolDeposit)
            || action == uint8(ScoreActions.ScoreEigenDeposit);
    }

    function _processAndEmitEvent(uint8 action, bytes32 queryId, uint64, bytes memory encodedTransaction)
        internal
        override
    {
        // sourceHeight is unused: scoring deadlines are bounded by the freshness window
        if (action == uint8(ScoreActions.ScoreDeposit)) {
            _scoreDeposits(queryId, encodedTransaction);
        } else if (action == uint8(ScoreActions.ScoreRepayment)) {
            _scoreRepayments(queryId, encodedTransaction);
        } else if (action == uint8(ScoreActions.ScoreLiquidation)) {
            _scoreLiquidations(queryId, encodedTransaction);
        } else if (action == uint8(ScoreActions.ScoreRocketPoolDeposit)) {
            _scoreRocketPoolDeposits(queryId, encodedTransaction);
        } else if (action == uint8(ScoreActions.ScoreEigenDeposit)) {
            _scoreEigenDeposits(queryId, encodedTransaction);
        } else {
            revert InvalidAction(action);
        }
    }

    /// @dev Shared CAPITAL crediting with the JOINT cap (the double-counting
    /// guard): every capital source draws from the same depositScoreOf
    /// accumulator against DEPOSIT_SCORE_CAP, so capital is counted once no
    /// matter how many protocols it is proven through. Above the cap — delta 0,
    /// but the event is still emitted (the deposit is verified and visible in
    /// history, as with the vault-deposit cap).
    function _creditCapital(address subject, uint256 amount, bytes32 queryId) internal {
        uint256 used = depositScoreOf[subject];
        uint256 delta = 0;
        if (used < DEPOSIT_SCORE_CAP) {
            uint256 room = DEPOSIT_SCORE_CAP - used;
            delta = amount > room ? room : amount;
            depositScoreOf[subject] = used + delta;
            borrowers[subject].ethScore += delta;
        }
        emit EthScoreIncreased(subject, delta, queryId);
    }

    function _scoreDeposits(bytes32 queryId, bytes memory encodedTransaction) internal {
        // _validateAndExtractLogs: transaction type, receiptStatus == 1 (invariant #1
        // (CLAUDE.md)), signature filter, every log must come from vaultOnSepolia
        EvmV1Decoder.LogEntry[] memory logs =
            _validateAndExtractLogs(encodedTransaction, DEPOSIT_EVENT_SIGNATURE, vaultOnSepolia);

        for (uint256 i; i < logs.length; i++) {
            require(logs[i].topics.length == 2, "Invalid FundsDeposited topics");
            require(logs[i].data.length == 64, "Invalid FundsDeposited data");

            address depositor = address(uint160(uint256(logs[i].topics[1])));
            // nonce — event uniqueness on the vault side; replay protection here
            // comes from queryId (invariant #3 (CLAUDE.md)), the nonce is unused
            (uint256 amount, ) = abi.decode(logs[i].data, (uint256, uint256));

            // Deposit contribution to the score is capped: protection against score
            // farming by circulating the same funds. The cap is JOINT across all
            // CAPITAL sources — see _creditCapital.
            _creditCapital(depositor, amount, queryId);
        }
    }

    /// @dev CAPITAL from a proven Rocket Pool deposit. The amount is native ETH
    /// (msg.value of RocketDepositPool.deposit) — the one external CAPITAL source
    /// homogeneous with vault deposits, so it enters the formula directly, drawing
    /// from the joint cap.
    function _scoreRocketPoolDeposits(bytes32 queryId, bytes memory encodedTransaction) internal {
        require(rocketDepositPoolSource != address(0), "rocket pool source not registered");
        EvmV1Decoder.LogEntry[] memory logs = _validateAndExtractLogs(
            encodedTransaction, RocketPoolParser.DEPOSIT_RECEIVED_TOPIC0, rocketDepositPoolSource
        );

        for (uint256 i; i < logs.length; i++) {
            RocketPoolParser.DepositReceived memory d = RocketPoolParser.parseDepositReceived(logs[i]);
            _creditCapital(d.from, d.amount, queryId);
        }
    }

    /// @dev CAPITAL from a proven EigenLayer restake. FLAT per event
    /// (EIGEN_DEPOSIT_FLAT_SCORE): strategy shares are heterogeneous LST units and
    /// never enter the formula. Draws from the joint cap — restaked LSTs cannot
    /// double-count capital already scored through other sources.
    function _scoreEigenDeposits(bytes32 queryId, bytes memory encodedTransaction) internal {
        require(eigenStrategyManagerSource != address(0), "eigen source not registered");
        EvmV1Decoder.LogEntry[] memory logs = _validateAndExtractLogs(
            encodedTransaction, EigenLayerParser.DEPOSIT_TOPIC0, eigenStrategyManagerSource
        );

        for (uint256 i; i < logs.length; i++) {
            EigenLayerParser.Deposit memory d = EigenLayerParser.parseDeposit(logs[i]);
            _creditCapital(d.staker, EIGEN_DEPOSIT_FLAT_SCORE, queryId);
        }
    }

    function _scoreRepayments(bytes32 queryId, bytes memory encodedTransaction) internal {
        EvmV1Decoder.LogEntry[] memory logs =
            _validateAndExtractLogs(encodedTransaction, REPAY_EVENT_SIGNATURE, loanBookOnSepolia);

        for (uint256 i; i < logs.length; i++) {
            require(logs[i].topics.length == 2, "Invalid LoanRepaidOnEth topics");
            require(logs[i].data.length == 64, "Invalid LoanRepaidOnEth data");

            address ethBorrower = address(uint160(uint256(logs[i].topics[1])));
            (, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));

            // Volume + a flat bonus for the repayment act itself: discipline is valued by frequency too
            uint256 delta = amount + FLAT_REPAYMENT_BONUS;
            borrowers[ethBorrower].ethScore += delta;
            emit EthScoreIncreased(ethBorrower, delta, queryId);
        }
    }

    /// @dev Negative signal: a proven liquidation of the borrower on the source chain.
    /// The event is Aave v3's real LiquidationCall (see LIQUIDATION_EVENT_SIGNATURE):
    /// topics = [sig, collateralAsset, debtAsset, user], data = abi.encode(debtToCover,
    /// liquidatedCollateralAmount, liquidator, receiveAToken). One parser for both the
    /// simulator and a real Aave deployment.
    /// Penalty is PER-EVENT with escalation: the first proven liquidation costs
    /// LIQUIDATION_PENALTY_FIRST (1 CTC) of earned bonus, each subsequent one
    /// LIQUIDATION_PENALTY_REPEAT (2 CTC), with the accumulated total capped at
    /// LIQUIDATION_PENALTY_CAP (5 CTC). debtToCover deliberately does NOT enter the
    /// formula — it is denominated in an arbitrary reserve token, and amounts across
    /// heterogeneous assets (6-decimal USDC vs 18-decimal DAI) cannot be compared
    /// trustlessly without price oracles; it is parsed and emitted for transparency.
    /// ethScore is NOT touched: the penalty accumulates separately and creditLimit
    /// clamps it to the earned bonus, so BASE_LIMIT is never lost (no hard lockout).
    function _scoreLiquidations(bytes32 queryId, bytes memory encodedTransaction) internal {
        EvmV1Decoder.LogEntry[] memory logs =
            _validateAndExtractLogs(encodedTransaction, LIQUIDATION_EVENT_SIGNATURE, loanBookOnSepolia);

        for (uint256 i; i < logs.length; i++) {
            require(logs[i].topics.length == 4, "Invalid LiquidationCall topics");
            require(logs[i].data.length == 128, "Invalid LiquidationCall data");

            address user = address(uint160(uint256(logs[i].topics[3])));
            (uint256 debtToCover,,,) = abi.decode(logs[i].data, (uint256, uint256, address, bool));

            // accumulated == 0 ⟺ no prior liquidation (the first penalty is nonzero)
            uint256 accumulated = borrowers[user].liquidationPenalty;
            uint256 penalty = accumulated == 0 ? LIQUIDATION_PENALTY_FIRST : LIQUIDATION_PENALTY_REPEAT;
            uint256 room = LIQUIDATION_PENALTY_CAP > accumulated ? LIQUIDATION_PENALTY_CAP - accumulated : 0;
            if (penalty > room) penalty = room;
            borrowers[user].liquidationPenalty = accumulated + penalty;
            // At the cap the penalty is 0, but the event is still emitted — the
            // liquidation is verified and visible in history (as with the deposit cap)
            emit LiquidationPenaltyApplied(user, penalty, debtToCover, queryId);
        }
    }

    // ---------- Credit limit ----------

    function creditLimit(address borrowerAddr) public view returns (uint256) {
        Borrower storage b = borrowers[borrowerAddr];
        if (b.ethScore < MIN_ETH_SCORE) return 0;

        uint256 base = BASE_LIMIT + ((b.ethScore - MIN_ETH_SCORE) * SCORE_SLOPE_NUM) / SCORE_SLOPE_DEN;
        if (base > MAX_BASE_LIMIT) base = MAX_BASE_LIMIT;

        // Earned bonus above the base: deposit/repayment slope part plus the localScore
        // part (localScore is stored in 1e18 units → normalize back to whole units).
        uint256 bonus = (base - BASE_LIMIT) + (b.localScore * LOCAL_SCORE_K) / 1 ether;
        // Liquidation penalties burn ONLY the earned bonus. The clamp floors the
        // penalized bonus at 0 and guarantees a liquidated borrower keeps BASE_LIMIT:
        // proven liquidations degrade the limit but can never hard-block borrowing.
        uint256 penalty = b.liquidationPenalty > bonus ? bonus : b.liquidationPenalty;
        return BASE_LIMIT + bonus - penalty;
    }

    // ---------- Loans ----------

    function borrow(uint256 amount) external returns (uint256 loanId) {
        require(amount > 0, "zero amount");

        Borrower storage b = borrowers[msg.sender];
        uint256 interestDue = (amount * INTEREST_RATE_BPS) / BPS_DENOMINATOR;
        uint256 totalDue = amount + interestDue;

        require(b.openDebt + totalDue <= creditLimit(msg.sender), "over credit limit");

        // No overdue loans: no open loan may be past its deadline
        uint256[] storage open = _openLoans[msg.sender];
        require(open.length < MAX_OPEN_LOANS, "too many open loans");
        for (uint256 i; i < open.length; i++) {
            require(block.number <= loans[open[i]].deadlineBlock, "overdue loan outstanding");
        }

        loanId = nextLoanId;
        nextLoanId += 1;

        // USCLoanManager state machine: Created → Funded. Here registration and
        // funding happen in one transaction, so Created is a transient state and
        // the loan is recorded as Funded immediately.
        loans[loanId] = Loan({
            borrower: msg.sender,
            principal: amount,
            interestDue: interestDue,
            repaidAmount: 0,
            usdcRepaidShare: 0,
            deadlineBlock: block.number + LOAN_DURATION_BLOCKS,
            status: LoanStatus.Funded,
            principalRepaid: 0
        });

        b.openDebt += totalDue;
        open.push(loanId);

        emit LoanOpened(loanId, msg.sender, amount, interestDue, block.number + LOAN_DURATION_BLOCKS);

        POOL.fund(msg.sender, amount);

        return loanId;
    }

    /// @notice GROSS amount due including the overdue penalty:
    /// principal + interestDue (+penalty). repaidAmount is NOT subtracted — this is
    /// the full price of the loan, not the remainder; a fully repaid loan returns the
    /// same value. The remaining amount payable is outstandingDueFor.
    /// After the deadline (or in Expired status) the interest part grows by
    /// LATE_PENALTY_BPS; the loan remains repayable — that is the rehabilitation path.
    function totalDueFor(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 baseDue = loan.principal + loan.interestDue;
        if (_isLate(loan)) {
            return baseDue + (loan.interestDue * LATE_PENALTY_BPS) / BPS_DENOMINATOR;
        }
        return baseDue;
    }

    /// @notice NET remainder due: totalDueFor minus what has already been paid.
    /// "How much is left to pay" for dashboards and the demo; 0 for a repaid loan.
    function outstandingDueFor(uint256 loanId) external view returns (uint256) {
        uint256 due = totalDueFor(loanId);
        uint256 repaid = loans[loanId].repaidAmount;
        return due > repaid ? due - repaid : 0;
    }

    function _isLate(Loan storage loan) internal view returns (bool) {
        return loan.status == LoanStatus.Expired || block.number > loan.deadlineBlock;
    }

    /// @notice Path A: repayment in native CTC. Principal is repaid first, then
    /// interest (and penalty); the whole amount goes to LPPool.absorb (part of the
    /// interest is burned there). Anyone may pay (msg.sender need not be the borrower).
    /// An overdue loan (Expired or past the deadline) is repaid with the
    /// LATE_PENALTY_BPS penalty on the interest part; full repayment moves it to
    /// Repaid and unblocks borrow, but localScore/loansCompleted are not accrued.
    function repayInCTC(uint256 loanId) external payable {
        require(msg.value > 0, "zero payment");

        Loan storage loan = loans[loanId];
        require(
            loan.status == LoanStatus.Funded || loan.status == LoanStatus.PartlyRepaid
                || loan.status == LoanStatus.Expired,
            "invalid loan status"
        );

        bool late = _isLate(loan);
        uint256 totalDue = totalDueFor(loanId);
        require(msg.value <= totalDue - loan.repaidAmount, "overpayment");

        // Principal/interest split: path A repays principal first (tracked by
        // principalRepaid, since path B may have already repaid part of the interest)
        uint256 principalOutstanding = loan.principal - loan.principalRepaid;
        uint256 principalPart = msg.value > principalOutstanding ? principalOutstanding : msg.value;
        loan.principalRepaid += principalPart;

        _applyRepayment(loanId, loan, msg.value, false, totalDue, late);

        POOL.absorb{value: msg.value}(principalPart);
    }

    /// @notice Path B: accounting for a repayment proven by RepaymentBridge (the wUSDC
    /// is already in its treasury). No CTC moves: settlement with the pool is the
    /// bridge's responsibility. The deadline is not checked here — the bridge checks it
    /// against the proof's delivery time. The path B share cap (~30%) is also enforced
    /// by the bridge; here only usdcRepaidShare accounting.
    /// The split is INTEREST-FIRST (mirroring path A): the bridged currency covers the
    /// profit part of the debt so the SwapDesk discount is paid out of the interest
    /// margin while the principal stays backed by hard CTC.
    /// @return principalPart Part of amount attributed to principal (the bridge tracks its treasury by it).
    /// @return interestPart Part of amount attributed to interest.
    function creditRepaymentFromBridge(uint256 loanId, uint256 amount)
        external
        onlyRepaymentBridge
        returns (uint256 principalPart, uint256 interestPart)
    {
        require(amount > 0, "zero amount");

        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Funded || loan.status == LoanStatus.PartlyRepaid, "invalid loan status");

        // Path B is always penalty-free: timeliness was checked by the bridge — the
        // loan deadline at proof delivery time + buffer, both sides on the CC3 scale
        uint256 totalDue = loan.principal + loan.interestDue;
        require(amount <= totalDue - loan.repaidAmount, "overpayment");

        loan.usdcRepaidShare += amount;

        // Interest first; the clamps prevent penalty payments from being counted as interest
        uint256 interestRepaid = loan.repaidAmount - loan.principalRepaid;
        uint256 interestOutstanding =
            loan.interestDue > interestRepaid ? loan.interestDue - interestRepaid : 0;
        interestPart = amount > interestOutstanding ? interestOutstanding : amount;
        principalPart = amount - interestPart;
        loan.principalRepaid += principalPart;

        _applyRepayment(loanId, loan, amount, true, totalDue, false);

        return (principalPart, interestPart);
    }

    /// @dev Shared repayment accounting for both paths: repaidAmount, openDebt, status,
    /// localScore on full repayment. On a late repayment (rehabilitation) the status
    /// becomes Repaid, but localScore/loansCompleted do not grow.
    function _applyRepayment(
        uint256 loanId,
        Loan storage loan,
        uint256 amount,
        bool viaBridge,
        uint256 totalDue,
        bool late
    ) internal {
        uint256 repaidBefore = loan.repaidAmount;
        loan.repaidAmount = repaidBefore + amount;

        Borrower storage b = borrowers[loan.borrower];

        // openDebt tracks only the base debt (principal + interest); the penalty was
        // never included in it — decrease it only by the base portion of the payment
        uint256 baseDue = loan.principal + loan.interestDue;
        uint256 baseOutstanding = repaidBefore >= baseDue ? 0 : baseDue - repaidBefore;
        uint256 basePortion = amount > baseOutstanding ? baseOutstanding : amount;
        b.openDebt -= basePortion;

        if (loan.repaidAmount >= totalDue) {
            loan.status = LoanStatus.Repaid;
            if (!late) {
                b.loansCompleted += 1;
                b.localScore += _localScoreDelta(loan);
            }
            _removeOpenLoan(loan.borrower, loanId);
            emit LoanRepaid(loanId);
        } else {
            // Expired stays Expired until full repayment — the loan still blocks
            // borrow and is repaid at the penalty rate
            if (loan.status != LoanStatus.Expired) {
                loan.status = LoanStatus.PartlyRepaid;
            }
            emit LoanPartiallyRepaid(loanId, amount, viaBridge);
        }
    }

    /// @dev localScore gain for a fully repaid (non-overdue) loan — proportional to
    /// the risk the pool took, not to the mere fact of repayment:
    ///   delta = principal × min(heldBlocks, LOAN_DURATION_BLOCKS)
    ///           / LOAN_DURATION_BLOCKS / LOCAL_SCORE_NORM_PRINCIPAL   (in 1e18 units)
    /// heldBlocks — CC3 blocks from issuance to the closing payment; for path B that
    /// is the proof delivery moment (creditRepaymentFromBridge), also on the CC3 scale.
    /// The issuance moment is not stored separately: deadlineBlock − LOAN_DURATION_BLOCKS.
    /// Protection against score farming via instant "borrow—repay" cycles: shorter
    /// than MIN_HOLD_BLOCKS — zero; above the threshold the reward is still
    /// proportional to amount × time, i.e. the credit limit cannot be bought cheaper
    /// than the interest paid.
    /// The min() clamp is needed for path B: delivery within DELIVERY_BUFFER_BLOCKS
    /// may arrive slightly after the deadline — counted as the full term, no more.
    function _localScoreDelta(Loan storage loan) internal view returns (uint256) {
        uint256 held = block.number - (loan.deadlineBlock - LOAN_DURATION_BLOCKS);
        if (held < MIN_HOLD_BLOCKS) return 0;
        if (held > LOAN_DURATION_BLOCKS) held = LOAN_DURATION_BLOCKS;
        return (loan.principal * held * 1 ether) / (LOAN_DURATION_BLOCKS * LOCAL_SCORE_NORM_PRINCIPAL);
    }

    function markLoanAsExpired(uint256 loanId) external onlyOwner {
        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Funded || loan.status == LoanStatus.PartlyRepaid, "loan not open");
        require(block.number > loan.deadlineBlock, "loan not overdue");

        loan.status = LoanStatus.Expired;
        emit LoanExpired(loanId);
    }

    function openLoansOf(address borrowerAddr) external view returns (uint256[] memory) {
        return _openLoans[borrowerAddr];
    }

    function _removeOpenLoan(address borrowerAddr, uint256 loanId) internal {
        uint256[] storage open = _openLoans[borrowerAddr];
        for (uint256 i; i < open.length; i++) {
            if (open[i] == loanId) {
                open[i] = open[open.length - 1];
                open.pop();
                return;
            }
        }
    }
}
