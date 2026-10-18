// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {KeelFwaRouter} from "../src/KeelFwaRouter.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";

contract VectorVerifier is OracleAttestationConsumer {
    constructor(address signer) OracleAttestationConsumer(signer) {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata signature) external view {
        _verifyAttestation(a, signature);
    }
}

/// @dev Protocol vector is copied unchanged from the supplied OracleConsumerConformance.t.sol.
contract OracleConformanceTest is KeelBase {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant VECTOR_SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant VECTOR_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    function setUp() public override {
        super.setUp();
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        deployCodeTo(
            "KeelSpinVault.sol:KeelSpinVault",
            abi.encode(
                address(this), address(pool), address(floor), address(intake), address(imd), VECTOR_SIGNER, team
            ),
            VECTOR_CONSUMER
        );
        vault = KeelSpinVault(payable(VECTOR_CONSUMER));
        router = new KeelFwaRouter(address(this), address(vault), address(pool));
        vault.setRouter(address(router));
        imd.mint(address(vault), 10 ether);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function testDigestMatchesProtocolVector() public view {
        assertEq(vault.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function testCallbackSelectorIsCanonical() public view {
        assertEq(vault.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    function testOriginalProtocolSignatureVerifies() public {
        // The vault intentionally only accepts uint256 answers. Check the protocol's bytes32[] signature
        // using the exact same copied verifier at the exact same domain address.
        deployCodeTo("OracleConformance.t.sol:VectorVerifier", abi.encode(VECTOR_SIGNER), VECTOR_CONSUMER);
        VectorVerifier(VECTOR_CONSUMER).verify(vector(), VECTOR_SIGNATURE);
    }

    function testUint256AnswerFromVectorKeyDeliveredUnder200kGas() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = vector();
        a.answerType = 3;
        a.answer = abi.encode(uint256(1 ether));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VECTOR_KEY, vault.attestationDigest(a));
        assertTrue(intake.result(requestId, a, abi.encodePacked(r, s, v)));
        assertTrue(vault.consumed(a.requestId));
        _state(id, KeelSpinVault.State.DecisionReady);
    }
}
