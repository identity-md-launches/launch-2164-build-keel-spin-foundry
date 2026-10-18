// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "src/KeelSpinVault.sol";
import {KeelFwaRouter} from "src/KeelFwaRouter.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {OracleBody} from "src/OracleBody.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract GasExhaustingTeam is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        assembly { for {} 1 {} {} }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract RejectPayment {
    receive() external payable {
        revert("reject ETH");
    }
}

contract TestSignerRegistry {
    address private immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Only the acquisition boundary is needed to test atomic rejection of malformed dependencies.
contract AcquisitionBoundaryPool {
    uint256 public fee = 0.1 ether;
    uint256 public vrf = 0.003 ether;
    uint256 public total = 0.103 ether;
    uint8 public response;

    function configure(uint256 fee_, uint256 vrf_, uint256 total_, uint8 response_) external {
        fee = fee_;
        vrf = vrf_;
        total = total_;
        response = response_;
    }

    function quoteAcquisitionPrice() external view returns (uint256, uint256, uint256) {
        return (fee, vrf, total);
    }

    function isPurchaseBlackout() external pure returns (bool) {
        return false;
    }

    function acquire(address, uint256, uint256, uint256, uint256) external payable returns (uint256[] memory ids) {
        ids = new uint256[](response == 0 ? 0 : response == 1 ? 2 : 1);
        if (response == 1) {
            ids[0] = 1;
            ids[1] = 2;
        }
        // response 2 deliberately leaves a single zero request id.
    }
}

contract KeelFailurePathsTest is KeelBase {
    event LowImdBalance(uint256 balance);
    event SaleProceeds(uint256 indexed roundId, bytes32 indexed saleTxHash, uint256 amount);
    event RoundStateChanged(uint256 indexed roundId, KeelSpinVault.State state);
    event OracleValueStored(uint256 indexed roundId, bytes32 indexed requestId, uint256 netOffer, uint64 expiresAt);

    /// forge-config: default.fuzz.runs = 128
    function testFuzzSignedMalformedAttestationLeavesPendingRequestIntact(uint8 mutationSeed) public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(1 ether);
        uint256 mutation = bound(mutationSeed, 0, 15);
        if (mutation == 0) a.chainId = 2;
        if (mutation == 1) a.answer = new bytes(31);
        if (mutation == 2) a.answer = new bytes(33);
        if (mutation == 3) a.panelSize = 4;
        if (mutation == 4) a.quorum = 3;
        if (mutation == 5) a.agreed = 3;
        if (mutation == 6) a.agreed = 6;
        if (mutation == 7) {
            a.quorum = 6;
            a.agreed = 6;
        }
        if (mutation == 8) a.issuedAt = uint64(block.timestamp - 301);
        if (mutation == 9) a.expiresAt = a.issuedAt + 3601;
        if (mutation == 10) {
            a.issuedAt = uint64(block.timestamp + 301);
            a.expiresAt = a.issuedAt + 3600;
        }
        if (mutation == 11) {
            a.issuedAt = uint64(block.timestamp - 1);
            a.expiresAt = a.issuedAt;
        }
        if (mutation == 12) a.answerType = 5;
        if (mutation == 13) a.answer = abi.encode(uint256(1e22 + 1));
        if (mutation == 14) a.expiresAt = a.issuedAt - 1;
        if (mutation == 15) vm.warp(block.timestamp + 3601);
        bytes32 beforeRound = keccak256(abi.encode(vault.rounds(id)));
        uint256 beforeBalance = address(vault).balance;
        assertFalse(intake.result(requestId, a, _sign(a)), "signed malformed attestation accepted");
        assertEq(keccak256(abi.encode(vault.rounds(id))), beforeRound);
        assertEq(vault.pending(requestId), id);
        assertFalse(vault.consumed(a.requestId));
        assertEq(address(vault).balance, beforeBalance);
        assertEq(nft.ownerOf(vault.rounds(id).tokenId), address(pool));
        // A rejected delivery must not prevent the independent deadline fallback.
        vm.warp(vault.fallbackAt(id));
        floor.set(0.5 ether, block.timestamp);
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(vault.pending(requestId), 0);
    }

    function testAttestationExpiryIsInclusiveThenExecutionExpiresOneSecondLater() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(2 ether);
        bytes memory signature = _sign(a);
        vm.warp(a.expiresAt);
        assertTrue(intake.result(requestId, a, signature), "valid at exact expiresAt");
        vm.warp(block.timestamp + 1);
        vm.expectRevert(KeelSpinVault.StaleAnswer.selector);
        vault.executeDecision(id);
        assertEq(nft.ownerOf(1), address(pool));
        vm.warp(vault.fallbackAt(id));
        vault.settleFallback(id);
        assertEq(nft.ownerOf(1), team);
    }

    function testExecutionAtExactAnswerExpiryAndMaximumOffer() public {
        (uint256 id,) = _ask();
        _answer(id, 1e22);
        vm.warp(vault.rounds(id).answerExpiresAt);
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(nft.ownerOf(1), team);
    }

    function testExactClockSkewToleranceIsAccepted() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(0);
        a.issuedAt = uint64(block.timestamp + 300);
        a.expiresAt = a.issuedAt + 3600;
        assertTrue(intake.result(requestId, a, _sign(a)));
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.Settled);
    }

    function testERC1271SignerCallbackFitsStipendAndRejectsWrongKey() public {
        TestSignerRegistry registry = new TestSignerRegistry(vm.addr(SIGNER_KEY));
        vault.setOracleSigner(address(registry));
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(2 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY + 1, vault.attestationDigest(a));
        assertFalse(intake.result(requestId, a, abi.encodePacked(r, s, v)));
        bytes memory signature = _sign(a);
        vm.cool(address(vault));
        vm.cool(address(pool));
        vm.cool(address(registry));
        assertTrue(intake.result(requestId, a, signature));
        _state(id, KeelSpinVault.State.DecisionReady);
        assertEq(nft.ownerOf(1), address(pool));
    }

    function testNonCanonicalHighSSignatureDoesNotConsumeRequest() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(2 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, vault.attestationDigest(a));
        uint256 order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory malleable = abi.encodePacked(r, bytes32(order - uint256(s)), uint8(v == 27 ? 28 : 27));
        assertFalse(intake.result(requestId, a, malleable));
        assertEq(vault.pending(requestId), id);
        assertTrue(intake.result(requestId, a, abi.encodePacked(r, s, v)));
    }

    function testOracleFailureCallbackRejectsUnknownAndConsumedIdsWithoutMovingAssets() public {
        (uint256 id, bytes32 requestId) = _ask();
        uint256 balance = address(vault).balance;
        vm.prank(address(intake));
        vm.expectRevert(KeelSpinVault.UnknownRequest.selector);
        vault.onFailure(keccak256("someone else's paid request"), 1, bytes32("body_invalid"), 0, 0, "");
        assertEq(vault.pending(requestId), id);
        vm.prank(address(intake));
        vault.onFailure(requestId, 1, bytes32("body_invalid"), 0, 0, "");
        assertEq(address(vault).balance, balance);
        assertEq(nft.ownerOf(1), address(pool));
        assertTrue(vault.rounds(id).oracleFailed);
        vm.prank(address(intake));
        vm.expectRevert(KeelSpinVault.UnknownRequest.selector);
        vault.onFailure(requestId, 1, bytes32("body_invalid"), 0, 0, "");
        floor.set(0.5 ether, block.timestamp);
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.Settled);
    }

    function testLowImdThresholdEventAfterExactPaymentAndStoredValueEvent() public {
        vault.withdrawIMD(team, 98 ether);
        assertFalse(vault.needsImdTopUp());
        uint256 id = _ready();
        vm.expectEmit(false, false, false, true, address(vault));
        emit LowImdBalance(1.5 ether);
        vault.requestDecision(id);
        assertTrue(vault.needsImdTopUp());
        bytes32 requestId = vault.rounds(id).oracleRequestId;
        OracleAttestation.Attestation memory a = _attestation(0);
        bytes memory signature = _sign(a);
        vm.expectEmit(true, false, false, true, address(vault));
        emit RoundStateChanged(id, KeelSpinVault.State.DecisionReady);
        vm.expectEmit(true, true, false, true, address(vault));
        emit OracleValueStored(id, requestId, 0, a.expiresAt);
        assertTrue(intake.result(requestId, a, signature));
    }

    function testAllSaleEventFieldsIdentifyCorrectRoundAndTransaction() public {
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        bytes32 txHash = keccak256("recorded marketplace transaction");
        vm.expectEmit(true, true, false, true, address(vault));
        emit SaleProceeds(id, txHash, 2 ether);
        vault.depositSaleProceeds{value: 2 ether}(id, txHash);
    }

    function testGasExhaustingNftRecipientCannotUndoKeepAndCanRetry() public {
        GasExhaustingTeam exhaust = new GasExhaustingTeam();
        vault.setTeamWallet(address(exhaust));
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision{gas: 1_500_000}(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertFalse(vault.rounds(id).nftForwarded);
        assertEq(nft.ownerOf(1), address(vault));
        assertEq(vault.activeRoundId(), 0);
        vault.setTeamWallet(team);
        vault.forwardNFT(id);
        assertEq(nft.ownerOf(1), team);
        vault.depositSaleProceeds{value: 2 ether}(id, keccak256("retry sale"));
        vm.prank(alice);
        vault.claim(id);
        assertEq(vault.accountedETH(), 0);
    }

    function testRejectingWithdrawalRecipientPreservesSharesAndCanRetryElsewhere() public {
        uint256 id = _fund();
        RejectPayment reject = new RejectPayment();
        bytes32 snapshot = keccak256(abi.encode(vault.rounds(id)));
        uint256 shares = vault.stake(id, alice);
        vm.prank(alice);
        vm.expectRevert(KeelSpinVault.TransferFailed.selector);
        vault.withdrawTo(id, payable(address(reject)));
        assertEq(vault.stake(id, alice), shares);
        assertEq(keccak256(abi.encode(vault.rounds(id))), snapshot);
        uint256 beforeBob = bob.balance;
        vm.prank(alice);
        vault.withdrawTo(id, payable(bob));
        assertEq(bob.balance - beforeBob, shares);
        assertEq(vault.totalSharesOutstanding(), 0);
    }

    function testRejectingFeeRecipientPreservesCreditAndCannotBlockBettorClaims() public {
        vault.setFeeBps(300);
        uint256 id = _ready();
        floor.set(0.5 ether, block.timestamp);
        _fallback(id);
        RejectPayment reject = new RejectPayment();
        uint256 credit = vault.feeCredit(team);
        vm.prank(team);
        vm.expectRevert(KeelSpinVault.TransferFailed.selector);
        vault.claimFees(payable(address(reject)));
        assertEq(vault.feeCredit(team), credit);
        vm.prank(alice);
        vault.claim(id);
        assertEq(address(vault).balance, credit);
        vm.prank(team);
        vault.claimFees(payable(bob));
        assertEq(address(vault).balance, 0);
    }

    function testZeroFeeAndInconsistentTotalRevertBeforeAnySpend() public {
        AcquisitionBoundaryPool broken = _boundaryPool();
        uint256 id = _fund();
        uint256 cash = vault.rounds(id).cash;
        broken.configure(0, 0.003 ether, 0.003 ether, 0);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.spin(id);
        broken.configure(0.1 ether, 0.003 ether, 0.1 ether, 0);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.spin(id);
        assertEq(address(vault).balance, cash);
        assertEq(vault.activeRoundId(), 0);
        assertEq(address(broken).balance, 0);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzzMalformedAcquisitionResponseRevertsAtomically(uint8 responseSeed) public {
        AcquisitionBoundaryPool broken = _boundaryPool();
        uint256 id = _fund();
        broken.configure(0.1 ether, 0.003 ether, 0.103 ether, uint8(bound(responseSeed, 0, 2)));
        bytes32 snapshot = keccak256(abi.encode(vault.rounds(id)));
        uint256 cash = address(vault).balance;
        uint256 beforeKeeper = keeper.balance;
        vm.prank(keeper);
        vm.expectRevert(KeelFwaRouter.InvalidConfiguration.selector);
        vault.spin(id);
        assertEq(keccak256(abi.encode(vault.rounds(id))), snapshot);
        assertEq(vault.accountedETH(), cash);
        assertEq(address(vault).balance, cash);
        assertEq(vault.activeRoundId(), 0);
        assertEq(keeper.balance, beforeKeeper);
        assertEq(address(broken).balance, 0);
        assertEq(address(router).balance, 0);
    }

    function _boundaryPool() private returns (AcquisitionBoundaryPool broken) {
        broken = new AcquisitionBoundaryPool();
        vault.setFwa(address(broken));
        router.setPool(address(broken));
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzDefinitionJsonRoundTripAndExactNftQuestion(bytes32 seed, uint16 lengthSeed) public {
        uint256 length = bound(lengthSeed, 1, 511);
        bytes memory definition = new bytes(length);
        for (uint256 i; i < length; ++i) {
            definition[i] = bytes1(uint8(32 + uint8(seed[i % 32]) % 95));
        }
        // Guarantee escaping is exercised even when the generated seed contains no delimiters.
        definition[0] = '"';
        if (length > 1) definition[1] = "\\";
        vault.setDefinition(0, string(definition));
        uint256 id = _ready();
        string memory body = string(vault.oracleBody(id));
        assertEq(vm.parseJsonString(body, ".definitions.offers"), string(definition));
        assertEq(vm.parseJsonString(body, ".definitions.sources"), vault.definitions(1));
        assertEq(vm.parseJsonString(body, ".definitions.net"), vault.definitions(2));
        assertEq(vm.parseJsonString(body, ".definitions.missing"), vault.definitions(3));
        string memory question = vm.parseJsonString(body, ".question");
        assertEq(
            question,
            string.concat(
                "What is the highest live offer, in wei, that the owner of ",
                vm.toLowercase(vm.toString(address(nft))),
                " token 1 could accept right now, after marketplace fees and creator royalties?"
            )
        );
        assertLt(bytes(body).length, 16 * 1024);
    }

    function testDefinitionLengthEdgesAndControlCharacters() public {
        bytes memory value = new bytes(511);
        for (uint256 i; i < value.length; ++i) {
            value[i] = "a";
        }
        vault.setDefinition(3, string(value));
        assertEq(bytes(vault.definitions(3)).length, 511);
        vm.expectRevert(OracleBody.InvalidDefinition.selector);
        vault.setDefinition(3, string(bytes.concat(value, bytes1("a"))));
        vm.expectRevert(OracleBody.InvalidDefinition.selector);
        vault.setDefinition(3, "");
        vm.expectRevert(OracleBody.InvalidDefinition.selector);
        vault.setDefinition(3, string(hex"007f"));
    }
}
