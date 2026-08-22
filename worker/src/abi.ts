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
];

export const REPAYMENT_VAULT_ABI = [
  'event UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)',
];

/** TruthGateBase.execute — shared by CreditCore and RepaymentBridge */
export const TRUTHGATE_EXECUTE_ABI = [
  'function execute(uint8 action, uint64 chainKey, uint64 blockHeight, bytes encodedTransaction, bytes32 merkleRoot, (bytes32 hash, bool isLeft)[] siblings, bytes32 lowerEndpointDigest, bytes32[] continuityRoots) returns (bool)',
  // Target events for finalization confirmation
  'event EthScoreIncreased(address indexed borrower, uint256 delta, bytes32 indexed queryId)',
  'event UsdcRepaymentProcessed(uint256 indexed ccLoanId, address indexed borrower, uint256 amount, bytes32 indexed queryId)',
];

/** Routing: event → (action, target contract). Action numbers come from
 * CreditCore.ScoreActions and RepaymentBridge.BridgeActions. */
export const EVENT_ROUTES = {
  FundsDeposited: { source: 'ScoringVault', action: 0, target: 'CreditCore' },
  LoanRepaidOnEth: { source: 'LoanBookSim', action: 1, target: 'CreditCore' },
  UsdcLockedForRepayment: { source: 'RepaymentVault', action: 0, target: 'RepaymentBridge' },
} as const;
