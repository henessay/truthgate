/**
 * Минимальные ABI-фрагменты. Сигнатуры событий обязаны побайтово совпадать с
 * контрактами (contracts/test/EventParity.t.sol — источник истины).
 */

export const SCORING_VAULT_ABI = [
  'event FundsDeposited(address indexed depositor, uint256 amount, uint256 nonce)',
  'function deposit() payable',
];

export const LOAN_BOOK_ABI = [
  'event LoanRepaidOnEth(address indexed borrower, uint256 loanId, uint256 amount)',
];

export const REPAYMENT_VAULT_ABI = [
  'event UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)',
];

/** TruthGateBase.execute — общий для CreditCore и RepaymentBridge */
export const TRUTHGATE_EXECUTE_ABI = [
  'function execute(uint8 action, uint64 chainKey, uint64 blockHeight, bytes encodedTransaction, bytes32 merkleRoot, (bytes32 hash, bool isLeft)[] siblings, bytes32 lowerEndpointDigest, bytes32[] continuityRoots) returns (bool)',
  // Целевые события для подтверждения финализации
  'event EthScoreIncreased(address indexed borrower, uint256 delta, bytes32 indexed queryId)',
  'event UsdcRepaymentProcessed(uint256 indexed ccLoanId, address indexed borrower, uint256 amount, bytes32 indexed queryId)',
];

/** Маршрутизация: событие → (action, целевой контракт). Числа action — из
 * CreditCore.ScoreActions и RepaymentBridge.BridgeActions. */
export const EVENT_ROUTES = {
  FundsDeposited: { source: 'ScoringVault', action: 0, target: 'CreditCore' },
  LoanRepaidOnEth: { source: 'LoanBookSim', action: 1, target: 'CreditCore' },
  UsdcLockedForRepayment: { source: 'RepaymentVault', action: 0, target: 'RepaymentBridge' },
} as const;
