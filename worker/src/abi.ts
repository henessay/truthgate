/**
 * Minimal ABI fragments. Event signatures MUST match the contracts byte-for-byte
 * (contracts/test/EventParity.t.sol is the source of truth).
 */

export const SCORING_VAULT_ABI = [
  'event FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce)',
  'function deposit() payable',
];

export const LOAN_BOOK_ABI = [
  'event LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount)',
  // Aave v3 Pool's real LiquidationCall layout (LoanBookSim mirrors it byte-for-byte,
  // so this single parser is valid against a real Aave deployment too)
  'event LiquidationCall(address indexed collateralAsset, address indexed debtAsset, address indexed user, uint256 debtToCover, uint256 liquidatedCollateralAmount, address liquidator, bool receiveAToken)',
];

export const REPAYMENT_VAULT_ABI = [
  'event UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)',
];

// External protocol singletons watched on Sepolia (v4 tiered bureau). These are
// canonical third-party deployments, not ours — identities recorded in
// docs/protocol-registry.json (Morpho per docs.morpho.org; Aave resolved from
// its AddressesProvider). They are registered as Verified sources on CreditCore
// by deploy-cc3.sh; both addresses must match that registration.
export const EXTERNAL_SOURCES = {
  MorphoBlueSepolia: '0xd011EE229E7459ba1ddd22631eF7bF528d424A14',
  AavePoolSepolia: '0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951',
} as const;

// NOTE: both protocols name their event "Repay" — the topic0s differ. Each ABI
// lives in its own fragment (its own Contract instance), and routing uses the
// distinct route keys AaveRepay/MorphoRepay, never the bare event name.
export const AAVE_POOL_ABI = [
  'event Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount, bool useATokens)',
];

export const MORPHO_BLUE_ABI = [
  'event Repay(bytes32 indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares)',
];

/** TruthGateBase.execute — shared by CreditCore and RepaymentBridge */
export const TRUTHGATE_EXECUTE_ABI = [
  'function execute(uint8 action, uint64 chainKey, uint64 blockHeight, bytes encodedTransaction, bytes32 merkleRoot, (bytes32 hash, bool isLeft)[] siblings, bytes32 lowerEndpointDigest, bytes32[] continuityRoots) returns (bool)',
  // Target events for finalization confirmation
  'event EthScoreIncreased(address indexed borrower, uint256 delta, bytes32 indexed queryId)',
  'event DisciplineScoreIncreased(address indexed borrower, uint256 delta, bytes32 indexed queryId)',
  'event LiquidationPenaltyApplied(address indexed borrower, uint256 penalty, uint256 debtToCover, bytes32 indexed queryId)',
  'event UsdcRepaymentProcessed(uint256 indexed ccLoanId, address indexed borrower, uint256 amount, bytes32 indexed queryId)',
];

/** Routing: route key → (action, target contract). Action numbers come from
 * CreditCore.ScoreActions and RepaymentBridge.BridgeActions. Route keys are
 * NOT always the Solidity event name: AaveRepay and MorphoRepay both watch an
 * event literally named "Repay" (different topic0s/layouts), so the keys stay
 * distinct and each watcher entry carries its own eventName alongside. */
export const EVENT_ROUTES = {
  FundsDeposited: { source: 'ScoringVault', action: 0, target: 'CreditCore' },
  LoanRepaidOnEth: { source: 'LoanBookSim', action: 1, target: 'CreditCore' },
  LiquidationCall: { source: 'LoanBookSim', action: 2, target: 'CreditCore' },
  AaveRepay: { source: 'AavePoolSepolia', action: 5, target: 'CreditCore' },
  MorphoRepay: { source: 'MorphoBlueSepolia', action: 6, target: 'CreditCore' },
  UsdcLockedForRepayment: { source: 'RepaymentVault', action: 0, target: 'RepaymentBridge' },
} as const;
