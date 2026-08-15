// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LPPool
/// @notice Пул ликвидности в нативном CTC. LP получают доли (shares), стоимость доли
/// растёт за счёт процентной части возвратов. Выдачу и приём возвратов инициирует
/// только CreditCore.
contract LPPool is Ownable {
    /// @notice Доля процентной части, сжигаемая при каждом возврате (1000 = 10%).
    uint256 public constant BURN_BPS = 1000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address public constant BURN_ADDRESS = address(0xdEaD);

    address public creditCore;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    /// @notice CTC, выданный под открытые займы. Входит в активы пула (требования к
    /// заёмщикам), но не является свободной ликвидностью для unstake.
    /// Погашения пути Б (wUSDC в казну RepaymentBridge) уменьшают эту величину не
    /// напрямую, а через settle(): мост продаёт wUSDC за CTC (swapWusdcForCtc) и
    /// немедленно заносит выручку сюда.
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

    /// @notice Сеттлмент пути Б: RepaymentBridge продал wUSDC из казны за CTC и заносит
    /// выручку в пул.
    /// @param principalReleased Высвобождаемый принципал — РОВНО та часть пришедшего
    /// CTC, что относится к телу (мост гарантирует principalReleased <= msg.value:
    /// дисконт SwapDesk целиком ложится на процентную часть выручки, недопокрытие
    /// тела из-за дисконта исключено constant-check'ом в конструкторе моста).
    /// Кламп по outstandingPrincipal — чисто защитный, при корректном учёте не срабатывает.
    function settle(uint256 principalReleased) external payable onlyBridge {
        require(principalReleased <= msg.value, "principal not cash-covered");
        uint256 released =
            principalReleased > outstandingPrincipal ? outstandingPrincipal : principalReleased;
        outstandingPrincipal -= released;

        emit Settled(released, msg.value);
    }

    /// @notice Активы пула: свободный баланс + выданное под открытые займы.
    function totalAssets() public view returns (uint256) {
        return address(this).balance + outstandingPrincipal;
    }

    /// @notice Внести нативный CTC, получить доли пропорционально текущим активам.
    function stake() external payable {
        require(msg.value > 0, "zero stake");

        // msg.value уже лежит на балансе — доли считаем от активов ДО взноса
        uint256 assetsBefore = totalAssets() - msg.value;
        uint256 minted = totalShares == 0 ? msg.value : (msg.value * totalShares) / assetsBefore;
        require(minted > 0, "stake too small");

        sharesOf[msg.sender] += minted;
        totalShares += minted;

        emit Staked(msg.sender, msg.value, minted);
    }

    /// @notice Сжечь доли и вывести CTC. Зарезервированное под открытые займы
    /// (outstandingPrincipal) вывести нельзя — выплата ограничена свободным балансом.
    /// @param shares Количество долей к погашению.
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

    /// @notice Выдача займа заёмщику. Только CreditCore.
    function fund(address to, uint256 amount) external onlyCreditCore {
        require(amount <= address(this).balance, "insufficient free liquidity");

        outstandingPrincipal += amount;

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "CTC transfer failed");

        emit Funded(to, amount);
    }

    /// @notice Приём возврата (тело + процент) в CTC. Только CreditCore.
    /// Из процентной части BURN_BPS сжигается на 0xdEaD, остальное остаётся в пуле
    /// и увеличивает стоимость доли LP.
    /// @param principal Часть msg.value, являющаяся возвратом тела займа; остаток —
    /// процент. Разбиение считает CreditCore (тело гасится первым).
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
