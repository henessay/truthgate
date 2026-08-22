// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TestUSDC} from "../src/sepolia/TestUSDC.sol";
import {ScoringVault} from "../src/sepolia/ScoringVault.sol";
import {LoanBookSim} from "../src/sepolia/LoanBookSim.sol";
import {RepaymentVault} from "../src/sepolia/RepaymentVault.sol";

/// @notice Deploys the source contracts on Sepolia. Run FIRST (DeployCC3 reads the
/// addresses from docs/deployments.json):
///   forge script script/DeploySepolia.s.sol --rpc-url sepolia --broadcast
contract DeploySepolia is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(pk);
        TestUSDC usdc = new TestUSDC();
        ScoringVault scoringVault = new ScoringVault();
        LoanBookSim loanBook = new LoanBookSim();
        RepaymentVault repaymentVault = new RepaymentVault(address(usdc));
        vm.stopBroadcast();

        string memory s = "sepolia";
        vm.serializeAddress(s, "TestUSDC", address(usdc));
        vm.serializeAddress(s, "ScoringVault", address(scoringVault));
        vm.serializeAddress(s, "LoanBookSim", address(loanBook));
        string memory sepoliaJson = vm.serializeAddress(s, "RepaymentVault", address(repaymentVault));

        vm.writeFile("../docs/deployments.json", string.concat("{\"sepolia\":", sepoliaJson, "}"));

        console2.log("TestUSDC:       ", address(usdc));
        console2.log("ScoringVault:   ", address(scoringVault));
        console2.log("LoanBookSim:    ", address(loanBook));
        console2.log("RepaymentVault: ", address(repaymentVault));
        console2.log("Addresses written to docs/deployments.json");
    }
}
