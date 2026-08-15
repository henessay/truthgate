// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {TruthGateBase} from "./TruthGateBase.sol";
import {CreditCore} from "./CreditCore.sol";
import {LPPool} from "./LPPool.sol";
import {WrappedUSDC} from "./WrappedUSDC.sol";

/// @title RepaymentBridge
/// @notice Путь Б погашения: единственный обработчик события UsdcLockedForRepayment
/// с Sepolia-контракта RepaymentVault. По доказанному локу USDC минтит wUSDC в свою
/// казну и засчитывает погашение в CreditCore (CTC не движется). Встроенный SwapDesk
/// продаёт wUSDC из казны за нативный CTC с дисконтом и немедленно заносит выручку
/// в LPPool.settle, высвобождая принципал пула.
contract RepaymentBridge is TruthGateBase {
    enum BridgeActions {
        UsdcRepayment // 0
    }
    error InvalidAction(uint8 action);

    // keccak256("UsdcLockedForRepayment(address,uint256,uint256)")
    // событие: UsdcLockedForRepayment(address indexed borrower, uint256 ccLoanId, uint256 amount)
    bytes32 public constant LOCK_EVENT_SIGNATURE =
        0xea18a20e09e48db6df74548f86c639bc49cf7f16771a510a49aa6b161bbc3f87;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Лимит доли пути Б: суммарные USDC-погашения по займу ≤ 30% от полной
    /// суммы к возврату (principal + interestDue). Остаток обязан прийти путём А.
    uint256 public constant USDC_SHARE_CAP_BPS = 3000;

    /// @notice Буфер на доставку proof'а: лок USDC на Sepolia, случившийся не позже
    /// deadlineBlock + буфер (по source-height), ещё принимается.
    /// v1-условность: deadlineBlock займа выражен в блоках CC3, а source-height — в
    /// блоках Sepolia; прямое сравнение — осознанное демо-упрощение.
    uint64 public constant DELIVERY_BUFFER_BLOCKS = 1000;

    /// @notice Курс v1: 1 wUSDC = 1 CTC (18 decimals с обеих сторон). Константа,
    /// потому что это тестнет и реальной цены пары нет; в проде здесь оракул.
    uint256 public constant CTC_PER_WUSDC_RATE = 1e18;

    /// @notice Нормализация decimals: событие UsdcLockedForRepayment несёт суммы в
    /// нативных единицах USDC (6 decimals), внутренний учёт (долг CTC, wUSDC,
    /// казна) — 18 decimals. Единственная точка, знающая про 6 decimals.
    uint256 public constant USDC_DECIMALS_SCALING = 1e12;

    /// @notice Дисконт SwapDesk: покупатель платит на 5% меньше номинала — премия за
    /// конвертацию казны в CTC для пула. Дисконт покрывается ПРОЦЕНТНОЙ частью казны
    /// пути Б, не телом (см. constant-check в конструкторе и swapWusdcForCtc).
    uint256 public constant DISCOUNT_BPS = 500;

    CreditCore public immutable CREDIT_CORE;
    LPPool public immutable POOL;
    WrappedUSDC public immutable WUSDC;

    /// @notice Источник события UsdcLockedForRepayment на Sepolia.
    address public repaymentVaultOnSepolia;

    /// @notice Номинал казны wUSDC, относящийся к телу займов (по разбиению
    /// CreditCore.creditRepaymentFromBridge). Инвариант:
    /// treasuryPrincipalFace + treasuryInterestFace == WUSDC.balanceOf(address(this)).
    uint256 public treasuryPrincipalFace;
    /// @notice Номинал казны wUSDC, относящийся к процентной части (маржа; из неё
    /// гасится дисконт SwapDesk).
    uint256 public treasuryInterestFace;

    event RepaymentVaultRegistered(address indexed vault);
    event UsdcRepaymentProcessed(
        uint256 indexed ccLoanId, address indexed borrower, uint256 amount, bytes32 indexed queryId
    );
    event WusdcSwapped(address indexed buyer, uint256 wusdcAmount, uint256 ctcPaid);

    constructor(address creditCore_, address payable pool_) {
        require(creditCore_ != address(0), "zero CreditCore");
        require(pool_ != address(0), "zero pool");
        CREDIT_CORE = CreditCore(creditCore_);
        POOL = LPPool(pool_);
        WUSDC = new WrappedUSDC(address(this));

        // Согласованность экономики пути Б: дисконт SwapDesk обязан покрываться
        // процентной маржой пути Б (спред над путём А, который дисконта не несёт).
        // Путь Б гасит долг процентом-первым, поэтому худшая доля процента в казне —
        // у займа, пробриджившего максимум: B_max = CAP·(P + I), I = P·r.
        //   доля процента s = I / B_max = r / (CAP·(1 + r))
        // Требуем s >= d (d = DISCOUNT_BPS), в bps-арифметике:
        //   R·1e8 >= D·C·(1e4 + R)
        // Текущие значения: 500·1e8 = 5.0e10 >= 500·3000·10500 = 1.575e10 ✓ — т.е.
        // минимальная процентная доля казны ~15.9% при дисконте 5%.
        uint256 rate = CREDIT_CORE.INTEREST_RATE_BPS();
        require(
            rate * 1e8 >= DISCOUNT_BPS * USDC_SHARE_CAP_BPS * (BPS_DENOMINATOR + rate),
            "discount not covered by path B interest margin"
        );
    }

    function registerRepaymentVault(address vault) external onlyOwner {
        require(vault != address(0), "zero vault");
        repaymentVaultOnSepolia = vault;
        emit RepaymentVaultRegistered(vault);
    }

    // Окно свежести к погашениям не применяется (политика CreditCore/CLAUDE.md):
    // своевременность здесь проверяется точнее — дедлайном по source-height.
    function _isFreshnessEnforced(uint8) internal pure override returns (bool) {
        return false;
    }

    function _processAndEmitEvent(uint8 action, bytes32 queryId, uint64 sourceHeight, bytes memory encodedTransaction)
        internal
        override
    {
        if (action != uint8(BridgeActions.UsdcRepayment)) {
            revert InvalidAction(action);
        }

        // Тип транзакции, receiptStatus == 1 (инвариант №1), сигнатура, каждый лог
        // обязан быть от зарегистрированного RepaymentVault
        EvmV1Decoder.LogEntry[] memory logs =
            _validateAndExtractLogs(encodedTransaction, LOCK_EVENT_SIGNATURE, repaymentVaultOnSepolia);

        for (uint256 i; i < logs.length; i++) {
            require(logs[i].topics.length == 2, "Invalid UsdcLockedForRepayment topics");
            require(logs[i].data.length == 64, "Invalid UsdcLockedForRepayment data");

            address borrower = address(uint160(uint256(logs[i].topics[1])));
            (uint256 ccLoanId, uint256 amount) = abi.decode(logs[i].data, (uint256, uint256));
            require(amount > 0, "zero repayment amount");

            // Событие в нативных 6-dec USDC → долг/wUSDC в 18-dec
            _processRepayment(queryId, sourceHeight, borrower, ccLoanId, amount * USDC_DECIMALS_SCALING);
        }
    }

    function _processRepayment(
        bytes32 queryId,
        uint64 sourceHeight,
        address borrower,
        uint256 ccLoanId,
        uint256 amount
    ) internal {
        (
            address loanBorrower,
            uint256 principal,
            uint256 interestDue,
            ,
            uint256 usdcRepaidShare,
            uint256 deadlineBlock,
        , ) = CREDIT_CORE.loans(ccLoanId);

        // Identity v1: платить через мост может только заёмщик займа (тот же EOA на
        // обоих чейнах) — чужой лок с чужим loanId не засчитывается
        require(loanBorrower == borrower, "borrower mismatch");

        // Дедлайн по SOURCE-height: важен момент лока USDC на Sepolia, а не момент
        // доставки proof'а на CC3 (доставку покрывает буфер)
        require(sourceHeight <= deadlineBlock + DELIVERY_BUFFER_BLOCKS, "repayment past deadline");

        // Лимит доли пути Б: не более 30% полной суммы возврата через USDC
        uint256 expectedRepayment = principal + interestDue;
        require(
            usdcRepaidShare + amount <= (expectedRepayment * USDC_SHARE_CAP_BPS) / BPS_DENOMINATOR,
            "USDC share cap exceeded"
        );

        // wUSDC — в казну моста (address(this)); SwapDesk конвертирует её в CTC для пула
        WUSDC.mint(address(this), amount);

        // CreditCore разбивает погашение процент-первым и возвращает разбиение —
        // по нему ведём номиналы казны для последующего свопа
        (uint256 principalPart, uint256 interestPart) = CREDIT_CORE.creditRepaymentFromBridge(ccLoanId, amount);
        treasuryPrincipalFace += principalPart;
        treasuryInterestFace += interestPart;

        emit UsdcRepaymentProcessed(ccLoanId, borrower, amount, queryId);
    }

    // ---------- SwapDesk ----------

    /// @notice Купить wUSDC из казны моста за нативный CTC по фиксированному курсу с
    /// дисконтом DISCOUNT_BPS. Выручка немедленно уходит в LPPool.settle.
    /// Продаваемый номинал списывается с казны пропорционально её составу
    /// (тело/процент); принципал высвобождается РОВНО на проданный номинал тела —
    /// он полностью покрыт пришедшим CTC, потому что дисконт целиком ложится на
    /// процентную часть выручки (гарантия — constant-check в конструкторе).
    function swapWusdcForCtc(uint256 wusdcAmount) external payable {
        require(wusdcAmount > 0, "zero amount");

        uint256 totalFace = treasuryPrincipalFace + treasuryInterestFace;
        require(wusdcAmount <= totalFace, "insufficient treasury");

        uint256 ctcRequired =
            (((wusdcAmount * CTC_PER_WUSDC_RATE) / 1e18) * (BPS_DENOMINATOR - DISCOUNT_BPS)) / BPS_DENOMINATOR;
        require(ctcRequired > 0, "amount too small");
        require(msg.value == ctcRequired, "wrong CTC amount");

        // Пропорциональное списание номиналов (округление вниз — в пользу процента,
        // безопасная сторона: тело не переоценивается)
        uint256 principalFaceSold = (wusdcAmount * treasuryPrincipalFace) / totalFace;
        uint256 interestFaceSold = wusdcAmount - principalFaceSold;
        treasuryPrincipalFace -= principalFaceSold;
        treasuryInterestFace -= interestFaceSold;

        // Пришедший CTC покрывает тело в первую очередь; недопокрытие от дисконта
        // гасится процентной частью выручки. Belt-and-braces к конструкторному check'у.
        require(msg.value >= principalFaceSold, "discount exceeds interest margin");

        POOL.settle{value: msg.value}(principalFaceSold);

        require(WUSDC.transfer(msg.sender, wusdcAmount), "wUSDC transfer failed");

        emit WusdcSwapped(msg.sender, wusdcAmount, msg.value);
    }
}
