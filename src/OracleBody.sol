// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

library OracleBody {
    error InvalidDefinition();

    /// @dev Definitions are printable ASCII, 1..511 bytes. Quotes and backslashes are JSON escaped.
    function escape(string memory value) internal pure returns (string memory) {
        bytes memory input = bytes(value);
        if (input.length == 0 || input.length >= 512) revert InvalidDefinition();
        bytes memory output = new bytes(input.length * 2);
        uint256 n;
        for (uint256 i; i < input.length; ++i) {
            bytes1 c = input[i];
            if (uint8(c) < 32 || uint8(c) > 126) revert InvalidDefinition();
            if (c == '"' || c == "\\") output[n++] = "\\";
            output[n++] = c;
        }
        assembly ("memory-safe") { mstore(output, n) }
        return string(output);
    }

    function build(address collection, uint256 tokenId, string[4] memory definitions)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            '{"v":1,"chainId":1,"answerType":"uint256","evidence":"panel","window":{"hours":1},',
            '"panelSize":5,"quorum":4,"toleranceBps":500,"validForSeconds":3600,"guards":{"min":"0","max":"10000000000000000000000"},',
            '"question":"What is the highest live offer, in wei, that the owner of ',
            Strings.toHexString(collection),
            " token ",
            Strings.toString(tokenId),
            ' could accept right now, after marketplace fees and creator royalties?",',
            '"definitions":{"offers":"',
            escape(definitions[0]),
            '","sources":"',
            escape(definitions[1]),
            '","net":"',
            escape(definitions[2]),
            '","missing":"',
            escape(definitions[3]),
            '"}}'
        );
    }
}
