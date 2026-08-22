// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LPPool
/// @notice Liquidity pool in native CTC. LPs receive shares; the share price grows
/// from the interest part of repayments. Issuance and repayment intake are initiated
/// only by CreditCore.
contract LPPool is Ownable {
    /// @notice Share of the interest part burned on every repayment (1000 = 10%).
    uint256 public constant BURN_BPS = 1000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address public constant BURN_ADDRESS = address(0xdEaD);

    address public creditCore;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    /// @notice CTC issued against open loans. Counts toward pool assets (claims on
    /// borrowers) but is not free liquidity available for unstake.
    /// Path B repayments (wUSDC into the RepaymentBridge treasury) decrease this
    /// value not directly but via settle(): the bridge sells wUSDC for CTC
    /// (swapWusdcForCtc) and immediately forwards the proceeds here.
    uint256 public outstandingPrincipal;

    address public bridge;

    event Staked(address indexed lp, uint256 amount, uint256 sharesMinted);
    event Unstaked(address indexed lp, uint256 amount, uint256 sharesBurned);
    event Funded(address indexed to, uint256 amount);
    event Absorbed(uint256 principal, uint256 interest, uint256 burned);
    event CreditCoreSet(address indexed creditCore);
    event BridgeSet(address indexed bridge);
    event Settled(uint256 principalReleased, uint256 ctcReceived);

    modifier onlyCreditCore() {
        require(msg.sender == creditCore, "not CreditCore");
        _;
    }

    modifier onlyBridge() {
        require(msg.sender == bridge, "not Bridge");
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setCreditCore(address newCreditCore) external onlyOwner {
        require(newCreditCore != address(0), "zero CreditCore");
        creditCore = newCreditCore;
        emit CreditCoreSet(newCreditCore);
    }

    function setBridge(address newBridge) external onlyOwner {
        require(newBridge != address(0), "zero bridge");
        bridge = newBridge;
        emit BridgeSet(newBridge);
    }

    /// @notice Path B settlement: RepaymentBridge sold wUSDC from its treasury for CTC
    /// and forwards the proceeds to the pool.
    /// @param principalReleased Principal being released — EXACTLY the part of the
    /// incoming CTC attributed to principal (the bridge guarantees
    /// principalReleased <= msg.value: the SwapDesk discount falls entirely on the
    /// interest part of the proceeds; a discount-driven principal shortfall is ruled
    /// out by the constant-check in the bridge's constructor).
    /// The clamp by outstandingPrincipal is purely defensive; with correct accounting it never fires.
    function settle(uint256 principalReleased) external payable onlyBridge {
        require(principalReleased <= msg.value, "principal not cash-covered");
        uint256 released =
            principalReleased > outstandingPrincipal ? outstandingPrincipal : principalReleased;
        outstandingPrincipal -= released;

        emit Settled(released, msg.value);
    }

    /// @notice Pool assets: free balance + amount issued against open loans.
    function totalAssets() public view returns (uint256) {
        return address(this).balance + outstandingPrincipal;
    }

    /// @notice Deposit native CTC and receive shares pro rata to current assets.
    function stake() external payable {
        require(msg.value > 0, "zero stake");

        // msg.value is already on the balance — shares are computed from assets BEFORE the deposit
        uint256 assetsBefore = totalAssets() - msg.value;
        uint256 minted = totalShares == 0 ? msg.value : (msg.value * totalShares) / assetsBefore;
        require(minted > 0, "stake too small");

        sharesOf[msg.sender] += minted;
        totalShares += minted;

        emit Staked(msg.sender, msg.value, minted);
    }

    /// @notice Burn shares and withdraw CTC. Funds reserved for open loans
    /// (outstandingPrincipal) cannot be withdrawn — payout is limited to the free balance.
    /// @param shares Number of shares to redeem.
    function unstake(uint256 shares) external {
        require(shares > 0, "zero shares");
        require(shares <= sharesOf[msg.sender], "insufficient shares");

        uint256 amount = (shares * totalAssets()) / totalShares;
        require(amount <= address(this).balance, "liquidity reserved for open loans");

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "CTC transfer failed");

        emit Unstaked(msg.sender, amount, shares);
    }

    /// @notice Loan issuance to a borrower. CreditCore only.
    function fund(address to, uint256 amount) external onlyCreditCore {
        require(amount <= address(this).balance, "insufficient free liquidity");

        outstandingPrincipal += amount;

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "CTC transfer failed");

        emit Funded(to, amount);
    }

    /// @notice Repayment intake (principal + interest) in CTC. CreditCore only.
    /// BURN_BPS of the interest part is burned to 0xdEaD; the rest stays in the pool
    /// and increases the LP share price.
    /// @param principal Part of msg.value that repays the loan principal; the
    /// remainder is interest. The split is computed by CreditCore (principal is repaid first).
    function absorb(uint256 principal) external payable onlyCreditCore {
        require(principal <= msg.value, "principal exceeds payment");
        require(principal <= outstandingPrincipal, "principal exceeds outstanding");

        outstandingPrincipal -= principal;

        uint256 interest = msg.value - principal;
        uint256 burned = (interest * BURN_BPS) / BPS_DENOMINATOR;
        if (burned > 0) {
            (bool ok, ) = BURN_ADDRESS.call{value: burned}("");
            require(ok, "burn failed");
        }

        emit Absorbed(principal, interest, burned);
    }
}
