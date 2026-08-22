//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {HawkFixture} from "./HawkFixture.sol";
import {HawkMetadata} from "../../contracts/hawk/HawkMetadata.sol";
import {HawkBaseRegistrar} from "../../contracts/hawk/HawkBaseRegistrar.sol";
import {HawkWrapper} from "../../contracts/hawk/HawkWrapper.sol";
import {CAN_DO_EVERYTHING} from "../../contracts/wrapper/INameWrapper.sol";

contract MetadataHarness is HawkMetadata {
    constructor(
        HawkBaseRegistrar _registrar,
        HawkWrapper _wrapper
    ) HawkMetadata(_registrar, _wrapper) {}

    function dateString(uint256 ts) external pure returns (string memory) {
        return _dateString(ts);
    }

    function escapeJSON(string memory s) external pure returns (string memory) {
        return _escapeJSON(s);
    }

    function escapeXML(string memory s) external pure returns (string memory) {
        return _escapeXML(s);
    }

    function decodeDNS(
        bytes memory dnsName
    )
        external
        pure
        returns (string memory, string memory, uint256, bool)
    {
        return _decodeDNS(dnsName);
    }
}

contract HawkMetadataTest is HawkFixture {
    uint256 constant YEAR = 365 days;
    MetadataHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new MetadataHarness(registrar, wrapper);
    }

    // ------------------------------------------------------------------
    // helpers under test
    // ------------------------------------------------------------------

    function test_dateVectors() public view {
        assertEq(harness.dateString(0), "1970-01-01");
        assertEq(harness.dateString(951782400), "2000-02-29"); // leap day
        assertEq(harness.dateString(1755475200), "2025-08-18");
        assertEq(harness.dateString(4102444800), "2100-01-01");
        assertEq(harness.dateString(1767225599), "2025-12-31");
        assertEq(harness.dateString(1767225600), "2026-01-01");
    }

    function test_escapeJSON() public view {
        assertEq(harness.escapeJSON("plain"), "plain");
        assertEq(harness.escapeJSON('has"quote'), 'has\\"quote');
        assertEq(harness.escapeJSON("back\\slash"), "back\\\\slash");
        assertEq(harness.escapeJSON("tab\there"), "tab\\u0009here");
        assertEq(harness.escapeJSON(unicode"emoji🐦ok"), unicode"emoji🐦ok");
    }

    function test_escapeXML() public view {
        assertEq(harness.escapeXML("plain"), "plain");
        assertEq(harness.escapeXML("a<b>c&d"), "a&lt;b&gt;c&amp;d");
        assertEq(harness.escapeXML('q"uote'), "q&quot;uote");
        assertEq(harness.escapeXML("apo'strophe"), "apo&#39;strophe");
        assertEq(harness.escapeXML("ctrl\x01byte"), "ctrl byte");
    }

    function test_decodeDNS() public view {
        (string memory display, string memory first, uint256 count, bool ok) = harness
            .decodeDNS(abi.encodePacked(uint8(9), "goldfinch", uint8(4), "hawk", uint8(0)));
        assertTrue(ok);
        assertEq(display, "goldfinch.hawk");
        assertEq(first, "goldfinch");
        assertEq(count, 2);

        (display, first, count, ok) = harness.decodeDNS(
            abi.encodePacked(uint8(4), "bot1", uint8(9), "goldfinch", uint8(4), "hawk", uint8(0))
        );
        assertTrue(ok);
        assertEq(display, "bot1.goldfinch.hawk");
        assertEq(count, 3);

        // malformed: length byte overruns
        (, , , ok) = harness.decodeDNS(abi.encodePacked(uint8(9), "abc"));
        assertFalse(ok);
        // malformed: missing terminator
        (, , , ok) = harness.decodeDNS(abi.encodePacked(uint8(3), "abc"));
        assertFalse(ok);
    }

    // ------------------------------------------------------------------
    // full token URIs
    // ------------------------------------------------------------------

    function test_tokenURI721_contents() public {
        _registerETH(alice, "goldfinch", YEAR);
        uint256 id = uint256(keccak256("goldfinch"));
        string memory uri = registrar.tokenURI(id);

        string memory json = _decodeDataURI(uri, "data:application/json;base64,");
        assertTrue(_contains(json, '"name":"goldfinch.hawk"'));
        assertTrue(_contains(json, '"trait_type":"Length","display_type":"number","value":9'));
        assertTrue(_contains(json, '"trait_type":"Expiration Date"'));
        assertTrue(_contains(json, '"image":"data:image/svg+xml;base64,'));

        string memory svg = _decodeDataURI(
            _extractImage(json),
            "data:image/svg+xml;base64,"
        );
        assertTrue(_contains(svg, "<svg xmlns"));
        assertTrue(_contains(svg, ">goldfinch</tspan>"));
        assertTrue(_contains(svg, ">.hawk</tspan>"));
        assertTrue(_contains(svg, "EXPIRES "));
    }

    function test_tokenURI721_graceBadge() public {
        _registerETH(alice, "goldfinch", YEAR);
        uint256 id = uint256(keccak256("goldfinch"));
        vm.warp(registrar.nameExpires(id) + 1);
        string memory json = _decodeDataURI(
            registrar.tokenURI(id),
            "data:application/json;base64,"
        );
        string memory svg = _decodeDataURI(
            _extractImage(json),
            "data:image/svg+xml;base64,"
        );
        assertTrue(_contains(svg, "IN GRACE PERIOD"));
    }

    function test_uri_wrappedNameAndSubname() public {
        _registerETH(alice, "goldfinch", YEAR);
        vm.startPrank(alice);
        registrar.setApprovalForAll(address(wrapper), true);
        wrapper.wrapETH2LD("goldfinch", alice, uint16(CAN_DO_EVERYTHING), address(0));
        bytes32 parentNode = _hawkNode("goldfinch");
        bytes32 subNode = wrapper.setSubnodeOwner(parentNode, "bot1", bob, 0, type(uint64).max);
        vm.stopPrank();

        string memory json = _decodeDataURI(
            wrapper.uri(uint256(parentNode)),
            "data:application/json;base64,"
        );
        assertTrue(_contains(json, '"name":"goldfinch.hawk"'));
        assertTrue(_contains(json, '"trait_type":"Kind","value":"Wrapped Name"'));

        json = _decodeDataURI(
            wrapper.uri(uint256(subNode)),
            "data:application/json;base64,"
        );
        assertTrue(_contains(json, '"name":"bot1.goldfinch.hawk"'));
        assertTrue(_contains(json, '"trait_type":"Kind","value":"Subname"'));
    }

    function test_tokenURI721_escapesHostileLabel() public {
        // register a hostile label directly (controller-level validity is
        // about length only; defence in depth for whatever gets through)
        string memory hostile = 'a"b<c>&d';
        vm.prank(address(controller));
        registrar.registerWithLabel(hostile, alice, YEAR);
        uint256 id = uint256(keccak256(bytes(hostile)));

        string memory json = _decodeDataURI(
            registrar.tokenURI(id),
            "data:application/json;base64,"
        );
        // JSON: quote escaped
        assertTrue(_contains(json, '"name":"a\\"b<c>&d.hawk"'));
        string memory svg = _decodeDataURI(
            _extractImage(json),
            "data:image/svg+xml;base64,"
        );
        // XML: angle brackets and ampersand escaped
        assertTrue(_contains(svg, ">a&quot;b&lt;c&gt;&amp;d</tspan>"));
    }

    function test_tokenURI721_emojiName() public {
        string memory emoji = unicode"🐦🐦🐦";
        _registerETH(alice, emoji, YEAR);
        uint256 id = uint256(keccak256(bytes(emoji)));
        string memory json = _decodeDataURI(
            registrar.tokenURI(id),
            "data:application/json;base64,"
        );
        assertTrue(_contains(json, string.concat('"name":"', emoji, '.hawk"')));
        assertTrue(_contains(json, '"value":3')); // 3 unicode chars
    }

    function test_uri_unknownNodeFallback() public {
        string memory json = _decodeDataURI(
            wrapper.uri(uint256(keccak256("no-such-node"))),
            "data:application/json;base64,"
        );
        assertTrue(_contains(json, '"name":"[0x'));
    }

    function test_contractURI() public view {
        string memory json = _decodeDataURI(
            registrar.contractURI(),
            "data:application/json;base64,"
        );
        assertTrue(_contains(json, '"name":"Hawk Names"'));
    }

    // ------------------------------------------------------------------
    // utilities
    // ------------------------------------------------------------------

    function _extractImage(
        string memory json
    ) internal pure returns (string memory) {
        bytes memory b = bytes(json);
        bytes memory key = bytes('"image":"');
        uint256 start = _indexOf(b, key, 0);
        require(start != type(uint256).max, "image not found");
        start += key.length;
        uint256 end = start;
        while (end < b.length && b[end] != '"') {
            end++;
        }
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function _decodeDataURI(
        string memory uri,
        string memory expectedPrefix
    ) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory prefix = bytes(expectedPrefix);
        require(b.length > prefix.length, "uri too short");
        for (uint256 i = 0; i < prefix.length; i++) {
            require(b[i] == prefix[i], "prefix mismatch");
        }
        bytes memory payload = new bytes(b.length - prefix.length);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[prefix.length + i];
        }
        return string(_base64Decode(payload));
    }

    function _base64Decode(
        bytes memory input
    ) internal pure returns (bytes memory) {
        bytes memory table = new bytes(256);
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (uint256 i = 0; i < 64; i++) {
            table[uint8(alphabet[i])] = bytes1(uint8(i));
        }
        uint256 len = input.length;
        uint256 padding = 0;
        while (padding < len && input[len - 1 - padding] == "=") {
            padding++;
        }
        uint256 outLen = (len / 4) * 3 - padding;
        bytes memory out = new bytes(outLen);
        uint256 j = 0;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 chunk = (uint256(uint8(table[uint8(input[i])])) << 18) |
                (uint256(uint8(table[uint8(input[i + 1])])) << 12) |
                (uint256(uint8(table[uint8(input[i + 2])])) << 6) |
                uint256(uint8(table[uint8(input[i + 3])]));
            if (j < outLen) out[j++] = bytes1(uint8(chunk >> 16));
            if (j < outLen) out[j++] = bytes1(uint8(chunk >> 8));
            if (j < outLen) out[j++] = bytes1(uint8(chunk));
        }
        return out;
    }

    function _indexOf(
        bytes memory haystack,
        bytes memory needle,
        uint256 from
    ) internal pure returns (uint256) {
        if (needle.length == 0 || haystack.length < needle.length) {
            return type(uint256).max;
        }
        for (uint256 i = from; i <= haystack.length - needle.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }
        return type(uint256).max;
    }

    function _contains(
        string memory haystack,
        string memory needle
    ) internal pure returns (bool) {
        return
            _indexOf(bytes(haystack), bytes(needle), 0) != type(uint256).max;
    }
}
