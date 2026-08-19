// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {TruthGateBase} from "./TruthGateBase.sol";
import {LPPool} from "./LPPool.sol";

/// @title CreditCore
/// @notice Кредитное ядро TruthGate на CC3. Скоринг растёт ТОЛЬКО из доказанных
/// Sepolia-событий (через TruthGateBase.execute), займы выдаются из LPPool в нативном
/// CTC, погашение — путь А (CTC сюда) или путь Б (wUSDC в казну RepaymentBridge,
/// здесь только учёт).
contract CreditCore is TruthGateBase {
    // ---------- Actions (скоринговые, приходят в execute) ----------
    enum ScoreActions {
        ScoreDeposit, // 0: депозит в vault на Sepolia
        ScoreRepayment // 1: погашение займа на Sepolia
    }
    error InvalidAction(uint8 action);

    // ---------- Сигнатуры потребляемых Sepolia-событий ----------
    // keccak256("FundsDeposited(address,uint256,uint256)")
    // событие: FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce)
    bytes32 public constant DEPOSIT_EVENT_SIGNATURE =
        0xbee4fe3675934fca827426c793623996a3079255089bda3a717019ffc5db2765;

    // keccak256("LoanRepaidOnEth(address,uint256,uint256)")
    // событие: LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount)
    bytes32 public constant REPAY_EVENT_SIGNATURE =
        0x9d2dba8b6b5cbf171f55f328240634b55005b55f505bfe0ac482893b92d0fd88;

    // ---------- Параметры кредитования (v1: фиксированные константы) ----------
    /// @notice Фиксированная ставка v1: 500 = 5% на срок займа.
    uint256 public constant INTEREST_RATE_BPS = 500;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @notice Срок займа в блоках CC3 (дедлайн пути А).
    uint256 public constant LOAN_DURATION_BLOCKS = 100_000;
    /// @notice Максимум открытых займов на заёмщика (ограничивает цикл проверки просрочки).
    uint256 public constant MAX_OPEN_LOANS = 8;

    // Кусочно-линейная формула лимита:
    //   ethScore < MIN_ETH_SCORE                 → лимит 0
    //   иначе base = BASE_LIMIT + (ethScore - MIN_ETH_SCORE) * SCORE_SLOPE_NUM / SCORE_SLOPE_DEN,
    //   base капится MAX_BASE_LIMIT; итог = base + localScore * LOCAL_SCORE_K.
    /// @notice Минимальный ethScore (в wei депозитов на Sepolia) для доступа к кредиту.
    uint256 public constant MIN_ETH_SCORE = 1e16; // 0.01 ETH
    /// @notice Первый лимит маленький: базовые 5 CTC на пороге MIN_ETH_SCORE.
    uint256 public constant BASE_LIMIT = 5 ether;
    /// @notice +10 CTC лимита за каждый 1 ETH score сверх порога (10 wei CTC на 1 wei score).
    uint256 public constant SCORE_SLOPE_NUM = 10;
    uint256 public constant SCORE_SLOPE_DEN = 1;
    uint256 public constant MAX_BASE_LIMIT = 500 ether;
    /// @notice Бонус к лимиту: +1 CTC за единицу localScore.
    uint256 public constant LOCAL_SCORE_K = 1 ether;
    /// @notice Прирост localScore за полностью погашенный займ на CC3.
    uint256 public constant LOCAL_SCORE_PER_LOAN = 1;
    /// @notice Штраф к процентной части при просроченном погашении: +50%.
    uint256 public constant LATE_PENALTY_BPS = 5000;
    /// @notice Кэп суммарного вклада ДЕПОЗИТОВ в ethScore на заёмщика. Депозиты — слабый
    /// сигнал (накручиваются циркуляцией депозит→вывод→депозит тех же средств), поэтому
    /// капятся; основной вес скора — погашения. Демо-масштаб: два средних депозита по
    /// 1 ETH; сверх кэпа депозит верифицируется и эмитит событие, но скор не растит.
    uint256 public constant DEPOSIT_SCORE_CAP = 2 ether;
    /// @notice Плоский бонус за каждый доказанный акт погашения на Sepolia: частота
    /// платёжной дисциплины имеет собственный вес, не только объём.
    uint256 public constant FLAT_REPAYMENT_BONUS = 0.1 ether;

    // ---------- Стейт-машина займа (форк USCLoanManager) ----------
    enum LoanStatus {
        None, // 0 — слот не занят; явная защита от "нулевой займ выглядит как Created"
        Created,
        Funded,
        PartlyRepaid,
        Repaid,
        Expired
    }

    struct Loan {
        address borrower;
        uint256 principal;
        uint256 interestDue; // фиксируется при выдаче: principal * INTEREST_RATE_BPS / 10000
        uint256 repaidAmount; // аккумулируется по обоим путям
        uint256 usdcRepaidShare; // доля, погашенная путём Б (лимит ~30% проверяет RepaymentBridge)
        uint256 deadlineBlock; // дедлайн пути А в блоках CC3
        LoanStatus status;
        // Сколько из repaidAmount отнесено на тело. Путь А гасит тело первым (твёрдый
        // CTC восстанавливает принципал пула), путь Б — процент первым (дисконт
        // SwapDesk ложится на процентную маржу, не на тело). Поле добавлено в конец
        // структуры, чтобы не менять позиции в существующем getter-кортеже.
        uint256 principalRepaid;
    }

    struct Borrower {
        uint256 ethScore; // растёт ТОЛЬКО из доказанных Sepolia-событий
        uint256 localScore; // растёт за погашенные займы на CC3
        uint256 openDebt; // суммарный непогашенный долг (тело + процент)
        uint256 loansCompleted;
    }

    LPPool public immutable POOL;

    address public vaultOnSepolia; // источник FundsDeposited
    address public loanBookOnSepolia; // источник LoanRepaidOnEth
    address public repaymentBridge; // единственный, кто может звать путь Б

    mapping(uint256 => Loan) public loans;
    mapping(address => Borrower) public borrowers;
    mapping(address => uint256[]) internal _openLoans;
    /// @notice Сколько ethScore заёмщик уже набрал депозитами (для DEPOSIT_SCORE_CAP).
    mapping(address => uint256) public depositScoreOf;

    uint256 public nextLoanId = 1;

    event EthScoreIncreased(address indexed borrower, uint256 delta, bytes32 indexed queryId);
    event LoanOpened(
        uint256 indexed loanId, address indexed borrower, uint256 principal, uint256 interestDue, uint256 deadlineBlock
    );
    event LoanPartiallyRepaid(uint256 indexed loanId, uint256 amount, bool viaBridge);
    event LoanRepaid(uint256 indexed loanId);
    event LoanExpired(uint256 indexed loanId);
    event VaultOnSepoliaRegistered(address indexed vault);
    event LoanBookOnSepoliaRegistered(address indexed loanBook);
    event RepaymentBridgeSet(address indexed bridge);

    modifier onlyRepaymentBridge() {
        require(msg.sender == repaymentBridge, "not RepaymentBridge");
        _;
    }

    constructor(address payable pool_) {
        require(pool_ != address(0), "zero pool");
        POOL = LPPool(pool_);
    }

    // ---------- Регистрация источников и моста ----------

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

    function setRepaymentBridge(address bridge) external onlyOwner {
        require(bridge != address(0), "zero bridge");
        repaymentBridge = bridge;
        emit RepaymentBridgeSet(bridge);
    }

    // ---------- Скоринг: приём доказанных Sepolia-событий ----------

    // Окно свежести (minAcceptedHeight) применяется к скоринговым action'ам.
    // Погашения пути Б в execute не приходят вовсе (их proof обрабатывает
    // RepaymentBridge), так что здесь все action'ы — скоринговые.
    function _isFreshnessEnforced(uint8 action) internal pure override returns (bool) {
        return action == uint8(ScoreActions.ScoreDeposit) || action == uint8(ScoreActions.ScoreRepayment);
    }

    function _processAndEmitEvent(uint8 action, bytes32 queryId, uint64, bytes memory encodedTransaction)
        internal
        override
    {
        // sourceHeight не используется: дедлайны скоринга ограничивает окно свежести
        if (action == uint8(ScoreActions.ScoreDeposit)) {
            _scoreDeposits(queryId, encodedTransaction);
        } else if (action == uint8(ScoreActions.ScoreRepayment)) {
            _scoreRepayments(queryId, encodedTransaction);
        } else {
            revert InvalidAction(action);
        }
    }

    function _scoreDeposits(bytes32 queryId, bytes memory encodedTransaction) internal {
        // _validateAndExtractLogs: тип транзакции, receiptStatus == 1 (инвариант №1),
        // фильтр по сигнатуре, каждый лог обязан быть от vaultOnSepolia
        EvmV1Decoder.LogEntry[] memory logs =
            _validateAndExtractLogs(encodedTransaction, DEPOSIT_EVENT_SIGNATURE, vaultOnSepolia);

        for (uint256 i; i < logs.length; i++) {
            require(logs[i].topics.length == 2, "Invalid FundsDeposited topics");
            require(logs[i].data.length == 64, "Invalid FundsDeposited data");

            address depositor = address(uint160(uint256(logs[i].topics[1])));
            // nonce — уникальность события на стороне vault'а; replay-защиту здесь
            // даёт queryId (инвариант №3), nonce не используем
            (uint256 amount, ) = abi.decode(logs[i].data, (uint256, uint256));

            // Вклад депозитов в скор капится: защита от накрутки циркуляцией одних
            // и тех же средств. Сверх кэпа — delta 0, но событие эмитится (депозит
            // верифицирован и виден в истории).
            uint256 used = depositScoreOf[depositor];
            uint256 delta = 0;
            if (used < DEPOSIT_SCORE_CAP) {
                uint256 room = DEPOSIT_SCORE_CAP - used;
                delta = amount > room ? room : amount;
                depositScoreOf[depositor] = used + delta;
                borrowers[depositor].ethScore += delta;
            }
            emit EthScoreIncreased(depositor, delta, queryId);
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

            // Объём + плоский бонус за сам акт погашения: дисциплина ценится и частотой
            uint256 delta = amount + FLAT_REPAYMENT_BONUS;
            borrowers[ethBorrower].ethScore += delta;
            emit EthScoreIncreased(ethBorrower, delta, queryId);
        }
    }

    // ---------- Кредитный лимит ----------

    function creditLimit(address borrowerAddr) public view returns (uint256) {
        Borrower storage b = borrowers[borrowerAddr];
        if (b.ethScore < MIN_ETH_SCORE) return 0;

        uint256 base = BASE_LIMIT + ((b.ethScore - MIN_ETH_SCORE) * SCORE_SLOPE_NUM) / SCORE_SLOPE_DEN;
        if (base > MAX_BASE_LIMIT) base = MAX_BASE_LIMIT;

        return base + b.localScore * LOCAL_SCORE_K;
    }

    // ---------- Займы ----------

    function borrow(uint256 amount) external returns (uint256 loanId) {
        require(amount > 0, "zero amount");

        Borrower storage b = borrowers[msg.sender];
        uint256 interestDue = (amount * INTEREST_RATE_BPS) / BPS_DENOMINATOR;
        uint256 totalDue = amount + interestDue;

        require(b.openDebt + totalDue <= creditLimit(msg.sender), "over credit limit");

        // Отсутствие просрочки: ни один открытый займ не должен быть за дедлайном
        uint256[] storage open = _openLoans[msg.sender];
        require(open.length < MAX_OPEN_LOANS, "too many open loans");
        for (uint256 i; i < open.length; i++) {
            require(block.number <= loans[open[i]].deadlineBlock, "overdue loan outstanding");
        }

        loanId = nextLoanId;
        nextLoanId += 1;

        // Стейт-машина USCLoanManager: Created → Funded. Здесь регистрация и
        // фондирование происходят в одной транзакции, поэтому Created — транзитное
        // состояние и займ сразу записывается как Funded.
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

    /// @notice Полная сумма к погашению с учётом штрафа за просрочку.
    /// После дедлайна (или в статусе Expired) процентная часть дорожает на
    /// LATE_PENALTY_BPS; займ остаётся погашаемым — это путь реабилитации.
    function totalDueFor(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        uint256 baseDue = loan.principal + loan.interestDue;
        if (_isLate(loan)) {
            return baseDue + (loan.interestDue * LATE_PENALTY_BPS) / BPS_DENOMINATOR;
        }
        return baseDue;
    }

    function _isLate(Loan storage loan) internal view returns (bool) {
        return loan.status == LoanStatus.Expired || block.number > loan.deadlineBlock;
    }

    /// @notice Путь А: погашение нативным CTC. Тело гасится первым, затем процент
    /// (и штраф); вся сумма уходит в LPPool.absorb (процентная часть частично
    /// сжигается там). Платить может кто угодно (msg.sender не обязан быть заёмщиком).
    /// Просроченный займ (Expired или за дедлайном) погашается со штрафом
    /// LATE_PENALTY_BPS к процентной части; полное погашение переводит его в Repaid
    /// и разблокирует borrow, но localScore/loansCompleted не начисляются.
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

        // Разбиение тело/процент: путь А гасит тело первым (по треку principalRepaid,
        // т.к. путь Б мог уже погасить часть процентов)
        uint256 principalOutstanding = loan.principal - loan.principalRepaid;
        uint256 principalPart = msg.value > principalOutstanding ? principalOutstanding : msg.value;
        loan.principalRepaid += principalPart;

        _applyRepayment(loanId, loan, msg.value, false, totalDue, late);

        POOL.absorb{value: msg.value}(principalPart);
    }

    /// @notice Путь Б: учёт погашения, доказанного RepaymentBridge (wUSDC уже в его
    /// казне). CTC не движется: сеттлмент с пулом — зона ответственности моста.
    /// Дедлайн здесь не проверяется — мост сверяет его с source-height proof'а.
    /// Лимит доли пути Б (~30%) тоже проверяет мост; здесь только учёт usdcRepaidShare.
    /// Разбиение — ПРОЦЕНТ ПЕРВЫМ (зеркально пути А): бридж-валюта покрывает
    /// профитную часть долга, чтобы дисконт SwapDesk гасился из процентной маржи,
    /// а тело оставалось обеспеченным твёрдым CTC.
    /// @return principalPart Часть amount, отнесённая на тело (мост ведёт по ней казну).
    /// @return interestPart Часть amount, отнесённая на процент.
    function creditRepaymentFromBridge(uint256 loanId, uint256 amount)
        external
        onlyRepaymentBridge
        returns (uint256 principalPart, uint256 interestPart)
    {
        require(amount > 0, "zero amount");

        Loan storage loan = loans[loanId];
        require(loan.status == LoanStatus.Funded || loan.status == LoanStatus.PartlyRepaid, "invalid loan status");

        // Путь Б всегда без штрафа: своевременность проверил мост — дедлайн займа
        // на момент доставки proof'а + буфер, обе стороны в CC3-шкале
        uint256 totalDue = loan.principal + loan.interestDue;
        require(amount <= totalDue - loan.repaidAmount, "overpayment");

        loan.usdcRepaidShare += amount;

        // Процент первым; клампы защищают от учёта штрафных выплат как процента
        uint256 interestRepaid = loan.repaidAmount - loan.principalRepaid;
        uint256 interestOutstanding =
            loan.interestDue > interestRepaid ? loan.interestDue - interestRepaid : 0;
        interestPart = amount > interestOutstanding ? interestOutstanding : amount;
        principalPart = amount - interestPart;
        loan.principalRepaid += principalPart;

        _applyRepayment(loanId, loan, amount, true, totalDue, false);

        return (principalPart, interestPart);
    }

    /// @dev Общий учёт погашения для обоих путей: repaidAmount, openDebt, статус,
    /// localScore при полном погашении. При late-погашении (реабилитация) статус
    /// становится Repaid, но localScore/loansCompleted не растут.
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

        // openDebt учитывает только базовый долг (тело + процент), в него штраф не
        // входил — уменьшаем только на базовую часть платежа
        uint256 baseDue = loan.principal + loan.interestDue;
        uint256 baseOutstanding = repaidBefore >= baseDue ? 0 : baseDue - repaidBefore;
        uint256 basePortion = amount > baseOutstanding ? baseOutstanding : amount;
        b.openDebt -= basePortion;

        if (loan.repaidAmount >= totalDue) {
            loan.status = LoanStatus.Repaid;
            if (!late) {
                b.loansCompleted += 1;
                b.localScore += LOCAL_SCORE_PER_LOAN;
            }
            _removeOpenLoan(loan.borrower, loanId);
            emit LoanRepaid(loanId);
        } else {
            // Expired остаётся Expired до полного погашения — займ по-прежнему
            // блокирует borrow и гасится по штрафной ставке
            if (loan.status != LoanStatus.Expired) {
                loan.status = LoanStatus.PartlyRepaid;
            }
            emit LoanPartiallyRepaid(loanId, amount, viaBridge);
        }
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
