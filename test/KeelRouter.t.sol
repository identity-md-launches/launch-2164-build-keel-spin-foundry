// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelFwaRouter} from "../src/KeelFwaRouter.sol";
import {LockedFWA, MockRewards, MockPermit2, MockTransferHelper} from "./mocks/BuilderRewards.sol";

contract KeelRouterTest is KeelBase {
    LockedFWA internal token;
    MockRewards internal rewards;
    MockTransferHelper internal helper;

    function setUp() public override {
        super.setUp();
        token = new LockedFWA();
        rewards = new MockRewards(address(token), address(pool));
        pool.setRewards(address(rewards), address(token));
        helper = new MockTransferHelper(address(token));
        token.setDistributor(address(helper), true);
        MockPermit2 permit = new MockPermit2();
        vm.etch(router.PERMIT2(), address(permit).code);
        vm.deal(address(rewards), 100 ether);
        rewards.credit(address(router), 0.01 ether);
    }

    function testHelperMustBeConfiguredBeforeClaim() public {
        vm.expectRevert(KeelFwaRouter.NotConfigured.selector);
        router.claimBuilderRewards(1 ether, block.timestamp + 1 hours);
    }

    function testBuilderRevenueToTeamViaNextBlockHelper() public {
        router.setTransferHelper(address(helper));
        uint256 out = router.claimBuilderRewards(9 ether, block.timestamp + 1 hours);
        assertEq(out, 10 ether);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(helper.claimable(team), 10 ether);
        assertEq(router.nextTransferNonce(), 1);
        vm.expectRevert("next block");
        helper.claim(team);
        vm.roll(block.number + 1);
        vm.prank(alice);
        helper.claim(team);
        assertEq(token.balanceOf(team), 10 ether);
    }

    function testLockedTokenCannotUseDirectTransfer() public {
        token.mint(address(router), 1 ether);
        vm.prank(address(router));
        vm.expectRevert("FWA transfer locked");
        token.transfer(team, 1 ether);
        router.setTransferHelper(address(helper));
        router.queueHeldBuilderRewards(1 ether, block.timestamp + 1 hours);
        vm.roll(block.number + 1);
        helper.claim(team);
        assertEq(token.balanceOf(team), 1 ether);
    }

    function testHelperFailureRollsBackRewardClaim() public {
        router.setTransferHelper(address(helper));
        helper.setEnabled(false);
        vm.expectRevert("helper disabled or wrong token");
        router.claimBuilderRewards(1 ether, block.timestamp + 1 hours);
        assertEq(rewards.tokenBuyAllowance(address(router)), 0.01 ether);
        assertEq(router.nextTransferNonce(), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function testScopeRejectsSignaturesOutsideActiveOwnerTransfer() public {
        assertEq(router.isValidSignature(bytes32(uint256(1)), ""), bytes4(0xffffffff));
        vm.prank(router.PERMIT2());
        assertEq(router.isValidSignature(bytes32(uint256(1)), ""), bytes4(0xffffffff));
    }

    function testRewardDeadlineMinimumAndPermission() public {
        router.setTransferHelper(address(helper));
        vm.expectRevert(KeelFwaRouter.DeadlineExpired.selector);
        router.claimBuilderRewards(1 ether, block.timestamp - 1);
        vm.expectRevert(KeelFwaRouter.InvalidAmount.selector);
        router.claimBuilderRewards(0, block.timestamp + 1);
        vm.expectRevert("minimum output");
        router.claimBuilderRewards(11 ether, block.timestamp + 1);
        vm.prank(alice);
        vm.expectRevert();
        router.claimBuilderRewards(1 ether, block.timestamp + 1);
    }

    function testEmergencyBuilderRecoveryUsesOnlyBuilderRevenue() public {
        uint256 id = _fund();
        uint256 vaultBalance = address(vault).balance;
        vm.expectRevert("core not in emergency");
        router.recoverBuilderAllowanceAsETH();
        rewards.setEmergency(true);
        uint256 beforeBalance = team.balance;
        router.recoverBuilderAllowanceAsETH();
        assertEq(team.balance - beforeBalance, 0.01 ether);
        assertEq(address(vault).balance, vaultBalance);
        assertEq(vault.rounds(id).cash, vaultBalance);
    }

    function testBuilderETHWithdrawCannotTakePurchaseRefund() public {
        vm.deal(address(router), 0.05 ether);
        pool.setRebate(0.01 ether);
        uint256 id = _fund();
        _spin(id);
        uint256 bettorReserve = vault.rounds(id).cash;
        uint256 beforeBalance = team.balance;
        router.withdrawBuilderETH();
        assertEq(team.balance - beforeBalance, 0.05 ether);
        assertEq(vault.rounds(id).cash, bettorReserve);
    }
}
