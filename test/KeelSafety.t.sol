// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {KeelFwaRouter} from "../src/KeelFwaRouter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract ReenteringBettor {
    KeelSpinVault public vault;
    uint256 public round;
    bool public reentered;
    uint256 public attempts;

    constructor(KeelSpinVault vault_) {
        vault = vault_;
    }

    function bet() external payable {
        vault.bet{value: msg.value}();
    }

    function withdraw(uint256 id) external {
        round = id;
        vault.withdraw(id);
    }

    function claim(uint256 id) external {
        round = id;
        vault.claim(id);
    }

    receive() external payable {
        ++attempts;
        (bool ok,) = address(vault).call(abi.encodeCall(vault.withdraw, (round)));
        (bool ok2,) = address(vault).call(abi.encodeCall(vault.claim, (round)));
        reentered = ok || ok2;
    }
}

contract RejectETH {
    function claimTo(KeelSpinVault vault, uint256 id, address payable recipient) external {
        vault.claimTo(id, recipient);
    }

    receive() external payable {
        revert("no ETH");
    }
}

contract FactoryProbe {
    function deploy(address owner_, address pool_, address floor_, address intake_, address imd_, address signer_)
        external
        returns (KeelSpinVault vault, KeelFwaRouter router)
    {
        vault = new KeelSpinVault(owner_, pool_, floor_, intake_, imd_, signer_, owner_);
        router = new KeelFwaRouter(owner_, address(vault), pool_);
    }
}

contract KeelSafetyTest is KeelBase {
    function testBetCannotBlockInitialRouterWiring() public {
        KeelSpinVault fresh = new KeelSpinVault(
            address(this), address(pool), address(floor), address(intake), address(imd), vm.addr(SIGNER_KEY), team
        );
        vm.prank(alice);
        vm.expectRevert(KeelSpinVault.NotConfigured.selector);
        fresh.bet{value: 0.001 ether}();
        KeelFwaRouter freshRouter = new KeelFwaRouter(address(this), address(fresh), address(pool));
        fresh.setRouter(address(freshRouter));
        vm.prank(alice);
        fresh.bet{value: 0.001 ether}();
        assertEq(fresh.stake(1, alice), 0.001 ether);
    }

    function testReentrantWithdrawalCannotDrainOtherBettors() public {
        ReenteringBettor attacker = new ReenteringBettor(vault);
        attacker.bet{value: 0.02 ether}();
        _bet(alice, 0.02 ether);
        attacker.withdraw(1);
        assertFalse(attacker.reentered());
        assertEq(attacker.attempts(), 1);
        assertEq(vault.withdrawable(1, alice), 0.02 ether);
        assertEq(address(attacker).balance, 0.02 ether);
        _solvent();
    }

    function testReentrantClaimCannotDrainOtherBettors() public {
        ReenteringBettor attacker = new ReenteringBettor(vault);
        uint256 target = vault.liveTarget();
        attacker.bet{value: target / 2}();
        _bet(alice, target / 2);
        _spin(1);
        _allocate(1);
        floor.set(0.5 ether, block.timestamp);
        _fallback(1);
        uint256 aliceClaim = vault.claimable(1, alice);
        attacker.claim(1);
        assertFalse(attacker.reentered());
        assertEq(vault.claimable(1, alice), aliceClaim);
        _solvent();
    }

    function testRejectingKeeperRollsBackSpinAndCanUseAnotherKeeper() public {
        uint256 id = _fund();
        RejectETH reject = new RejectETH();
        vm.prank(address(reject));
        vm.expectRevert(KeelSpinVault.TransferFailed.selector);
        vault.spin(id);
        _state(id, KeelSpinVault.State.Open);
        assertEq(vault.activeRoundId(), 0);
        _spin(id);
        _state(id, KeelSpinVault.State.Spinning);
    }

    function testRejectingBettorCanClaimToAnotherAddress() public {
        RejectETH reject = new RejectETH();
        uint256 target = vault.liveTarget();
        vm.deal(address(reject), target);
        vm.prank(address(reject));
        vault.bet{value: target}();
        _spin(1);
        _allocate(1);
        floor.set(0.5 ether, block.timestamp);
        _fallback(1);
        uint256 amount = vault.claimable(1, address(reject));
        vm.prank(address(reject));
        vm.expectRevert(KeelSpinVault.TransferFailed.selector);
        vault.claim(1);
        assertEq(vault.claimable(1, address(reject)), amount);
        uint256 beforeBalance = alice.balance;
        reject.claimTo(vault, 1, payable(alice));
        assertEq(alice.balance - beforeBalance, amount);
        _solvent();
    }

    function testOwnerHasNoBettorEthWithdrawalPower() public {
        _fund();
        uint256 beforeBalance = address(vault).balance;
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.withdraw(1);
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.claimFees(payable(address(this)));
        (bool success,) =
            address(vault).call(abi.encodeWithSignature("withdrawETH(address,uint256)", address(this), beforeBalance));
        assertFalse(success);
        assertEq(address(vault).balance, beforeBalance);
    }

    function testPrivilegedSettersRejectNonOwner() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setBetsPaused(true);
        vm.expectRevert();
        vault.setTeamWallet(alice);
        vm.expectRevert();
        vault.setFeeBps(200);
        vm.expectRevert();
        vault.setFwa(alice);
        vm.expectRevert();
        vault.setFloorOracle(alice);
        vm.expectRevert();
        vault.setIntake(alice);
        vm.expectRevert();
        vault.setIMD(alice);
        vm.expectRevert();
        vault.setOracleSigner(alice);
        vm.expectRevert();
        vault.withdrawIMD(alice, 1);
        vm.expectRevert();
        router.setPool(alice);
        vm.expectRevert();
        router.setTransferHelper(alice);
        vm.expectRevert();
        router.withdrawBuilderETH();
        vm.stopPrank();
    }

    function testParameterBounds() public {
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setBetParameters(1, 501, 500);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setBetParameters(1, 0, 500);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setBetParameters(0, 500, 500);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setSpinParameters(0, 0, 0, 0);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setDecisionParameters(10001, 500, 24 hours, 2 hours, 1 hours, 10 minutes, true);
        vm.expectRevert(KeelSpinVault.InvalidAddress.selector);
        vault.setTeamWallet(address(vault));
        vm.expectRevert(KeelSpinVault.InvalidAddress.selector);
        vault.setIntake(address(0));
    }

    function testPaidUUIDCannotBeReusedForAnotherOwnRequest() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(0);
        bytes memory signature = _sign(a);
        assertTrue(intake.result(requestId, a, signature));
        vault.executeDecision(id);
        (, bytes32 anotherRequest) = _ask();
        assertFalse(intake.result(anotherRequest, a, signature));
        assertGt(vault.pending(anotherRequest), 0);
    }

    function testStaticConstructorsWorkWithNoDependencyCodeAndExplicitOwner() public {
        FactoryProbe factory = new FactoryProbe();
        // These are the launch's supplied public dependencies, intentionally without mocked code.
        (KeelSpinVault created, KeelFwaRouter createdRouter) = factory.deploy(
            0x51A9CA901c0cb5c222D244b2CcB0ebfc5C9ABa99,
            0x958C41181182e76F221331b2755b77D9e1426A98,
            0xaA4D9009a4664604b57644bF13e447E9036727DC,
            0xa43e6F75ee006411F79Ac1C84120606C2330DE82,
            0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
            0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982
        );
        assertEq(created.owner(), created.teamWallet());
        assertEq(createdRouter.owner(), created.owner());
        assertNotEq(created.owner(), address(factory));
        assertEq(createdRouter.vault(), address(created));
        assertEq(address(created.router()), address(0));
    }

    function testApplicationRuntimeSizeAndForbiddenOpcodes() public view {
        _checkCode(address(vault).code);
        _checkCode(address(router).code);
    }

    function _checkCode(bytes memory code) internal pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }
}
