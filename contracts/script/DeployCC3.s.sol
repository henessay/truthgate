// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LPPool} from "../src/cc3/LPPool.sol";
import {CreditCore} from "../src/cc3/CreditCore.sol";
import {RepaymentBridge} from "../src/cc3/RepaymentBridge.sol";

/// @notice Deploys the CC3 contracts + wires them together + registers the Sepolia
/// source contracts. Run AFTER DeploySepolia (reads addresses from docs/deployments.json):
///   forge script script/DeployCC3.s.sol --rpc-url cc3 --broadcast
contract DeployCC3 is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        string memory file = vm.readFile("../docs/deployments.json");
        address usdcSepolia = vm.parseJsonAddress(file, ".sepolia.TestUSDC");
        address scoringVault = vm.parseJsonAddress(file, ".sepolia.ScoringVault");
        address loanBook = vm.parseJsonAddress(file, ".sepolia.LoanBookSim");
        address repaymentVault = vm.parseJsonAddress(file, ".sepolia.RepaymentVault");

        vm.startBroadcast(pk);
        LPPool pool = new LPPool();
        // 0,0 → production defaults (100_000 / 25_000); a demo deploy passes compressed
        // values via env to deploy-cc3.sh (LOAN_DURATION_BLOCKS / MIN_HOLD_BLOCKS)
        CreditCore core = new CreditCore(payable(address(pool)), 0, 0);
        RepaymentBridge bridge = new RepaymentBridge(address(core), payable(address(pool)));

        pool.setCreditCore(address(core));
        pool.setBridge(address(bridge));
        core.setRepaymentBridge(address(bridge));

        core.registerVaultOnSepolia(scoringVault);
        core.registerLoanBookOnSepolia(loanBook);
        bridge.registerRepaymentVault(repaymentVault);
        vm.stopBroadcast();

        // Rebuild deployments.json: the sepolia section (from what was read) + cc3
        string memory s = "sepolia";
        vm.serializeAddress(s, "TestUSDC", usdcSepolia);
        vm.serializeAddress(s, "ScoringVault", scoringVault);
        vm.serializeAddress(s, "LoanBookSim", loanBook);
        string memory sepoliaJson = vm.serializeAddress(s, "RepaymentVault", repaymentVault);

        string memory c = "cc3";
        vm.serializeAddress(c, "LPPool", address(pool));
        vm.serializeAddress(c, "CreditCore", address(core));
        vm.serializeAddress(c, "RepaymentBridge", address(bridge));
        string memory cc3Json = vm.serializeAddress(c, "WrappedUSDC", address(bridge.WUSDC()));

        vm.writeFile(
            "../docs/deployments.json",
            string.concat("{\"sepolia\":", sepoliaJson, ",\"cc3\":", cc3Json, "}")
        );

        console2.log("LPPool:          ", address(pool));
        console2.log("CreditCore:      ", address(core));
        console2.log("RepaymentBridge: ", address(bridge));
        console2.log("WrappedUSDC:     ", address(bridge.WUSDC()));
        console2.log("Addresses written to docs/deployments.json");
    }
}
