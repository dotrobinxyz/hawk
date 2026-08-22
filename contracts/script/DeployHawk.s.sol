//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {Script, console2} from "forge-std/Script.sol";

import {HawkRegistry} from "../contracts/hawk/HawkRegistry.sol";
import {HawkBaseRegistrar} from "../contracts/hawk/HawkBaseRegistrar.sol";
import {HawkRegistrarController} from "../contracts/hawk/HawkRegistrarController.sol";
import {HawkPriceOracle, AggregatorV3Interface} from "../contracts/hawk/HawkPriceOracle.sol";
import {HawkReservedList} from "../contracts/hawk/HawkReservedList.sol";
import {HawkWrapper} from "../contracts/hawk/HawkWrapper.sol";
import {HawkMetadata} from "../contracts/hawk/HawkMetadata.sol";
import {IHawkPriceOracle} from "../contracts/hawk/IHawkPriceOracle.sol";
import {MockAggregator} from "../contracts/hawk/mocks/MockAggregator.sol";
import {MockUSDC} from "../contracts/hawk/mocks/MockUSDC.sol";

import {ReverseRegistrar} from "../contracts/reverseRegistrar/ReverseRegistrar.sol";
import {DefaultReverseRegistrar} from "../contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {PublicResolver} from "../contracts/resolvers/PublicResolver.sol";
import {UniversalResolver} from "../contracts/universalResolver/UniversalResolver.sol";
import {GatewayProvider} from "../contracts/ccipRead/GatewayProvider.sol";
import {INameWrapper} from "../contracts/wrapper/INameWrapper.sol";
import {IMetadataService} from "../contracts/wrapper/IMetadataService.sol";
import {IBaseRegistrar} from "../contracts/ethregistrar/IBaseRegistrar.sol";
import {IReverseRegistrar} from "../contracts/reverseRegistrar/IReverseRegistrar.sol";
import {IDefaultReverseRegistrar} from "../contracts/reverseRegistrar/IDefaultReverseRegistrar.sol";
import {ENS} from "../contracts/registry/ENS.sol";
import {IPriceOracle} from "../contracts/ethregistrar/IPriceOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Deploys and wires the complete Hawk stack from a per-network JSON
///         config (script/config/<HAWK_NETWORK>.json), sanity-checks the
///         wiring, hands ownership to the configured final owner, and writes
///         a deployment record to deployments/hawk-<HAWK_NETWORK>.json.
///
///         Usage:
///           HAWK_NETWORK=local forge script script/DeployHawk.s.sol \
///             --rpc-url $RPC --broadcast [--verify]
///
///         The deployer key comes from the standard forge mechanisms
///         (--private-key / --account / hardware wallet). No secrets live in
///         this repo.
contract DeployHawk is Script {
    // Deployed instances live in storage to keep run() within stack limits.
    HawkRegistry registry;
    HawkBaseRegistrar registrar;
    ReverseRegistrar reverseRegistrar;
    DefaultReverseRegistrar defaultReverseRegistrar;
    HawkReservedList reservedList;
    HawkPriceOracle oracle;
    HawkWrapper wrapper;
    HawkMetadata metadata;
    HawkRegistrarController controller;
    PublicResolver resolver;
    GatewayProvider gatewayProvider;
    UniversalResolver universalResolver;
    address usdc;
    address feed;
    uint256 promoEnd;

    // Locked pricing: attoUSD per second for $100/$25/$5 per 365-day year.
    // 1–2 char names are unregisterable (controller `valid`); priced as
    // 3-char defensively.
    uint256 constant RATE3 = 3170979198376;
    uint256 constant RATE4 = 792744799594;
    uint256 constant RATE5 = 158548959918;

    bytes32 constant HAWK_NODE =
        0xf431efc1fb1b854a38191ac67de7e1ee70205b40f71cb927c938685e82e05403;
    bytes32 constant HAWK_LABELHASH =
        0x20a425b46037bc1d600066c89af6258ff77bbf40ae831044e2d8f4a1605fc5f6;
    bytes32 constant REVERSE_LABELHASH = keccak256("reverse");
    bytes32 constant ADDR_LABELHASH = keccak256("addr");

    struct Config {
        address usdc; // 0 → deploy MockUSDC (non-mainnet only)
        address ethUsdFeed; // 0 → deploy MockAggregator (non-mainnet only)
        int256 mockEthPriceUSD8; // used only when deploying the mock feed
        uint256 gracePeriod;
        uint256 minRegistrationDuration;
        uint256 maxFeedAge;
        uint256 minCommitmentAge;
        uint256 maxCommitmentAge;
        uint256 premiumStartAttoUSD;
        uint256 premiumDays;
        uint256 promoDurationSeconds; // 0 → no promo
        string batchGatewayUrl;
        address finalOwner; // 0 → deployer keeps ownership (non-mainnet only)
        bool isMainnet;
    }

    function run() external {
        string memory network = vm.envString("HAWK_NETWORK");
        Config memory cfg = _readConfig(network);

        address deployer = msg.sender;
        address finalOwner = cfg.finalOwner == address(0)
            ? deployer
            : cfg.finalOwner;

        if (cfg.isMainnet) {
            require(
                cfg.finalOwner != address(0),
                "mainnet requires an explicit finalOwner (multisig)"
            );
            require(
                cfg.usdc != address(0) && cfg.ethUsdFeed != address(0),
                "mainnet requires real USDC and feed addresses"
            );
            require(cfg.gracePeriod == 90 days, "mainnet grace must be 90 days");
            require(
                cfg.minRegistrationDuration == 28 days,
                "mainnet min duration must be 28 days"
            );
        }

        vm.startBroadcast();

        _deployDependencies(cfg);
        _deployCore(cfg, deployer);
        // Seed reservations BEFORE the controller is constructed or enabled.
        // After _deployCore the only registrar controller is the wrapper,
        // whose sole registration entrypoint is itself onlyController on a
        // wrapper with no controllers yet — so no public registration path
        // exists. Seeding here (security-review LOW-1) means reserved names
        // are in place before the controller can ever register one; there is
        // no window where the controller is live but reservations are absent.
        _seedReservations();
        _deployControllerAndResolvers(cfg, finalOwner);
        _sanityCheck(cfg);
        _handover(finalOwner, deployer);

        vm.stopBroadcast();

        // ---- record ----
        string memory out = "deployment";
        vm.serializeUint(out, "chainId", block.chainid);
        vm.serializeUint(out, "deployedAt", block.timestamp);
        vm.serializeUint(out, "promoEnd", promoEnd);
        vm.serializeAddress(out, "deployer", deployer);
        vm.serializeAddress(out, "finalOwner", finalOwner);
        vm.serializeAddress(out, "usdc", usdc);
        vm.serializeAddress(out, "ethUsdFeed", feed);
        vm.serializeAddress(out, "HawkRegistry", address(registry));
        vm.serializeAddress(out, "HawkBaseRegistrar", address(registrar));
        vm.serializeAddress(out, "HawkRegistrarController", address(controller));
        vm.serializeAddress(out, "HawkPriceOracle", address(oracle));
        vm.serializeAddress(out, "HawkReservedList", address(reservedList));
        vm.serializeAddress(out, "HawkWrapper", address(wrapper));
        vm.serializeAddress(out, "HawkMetadata", address(metadata));
        vm.serializeAddress(out, "ReverseRegistrar", address(reverseRegistrar));
        vm.serializeAddress(
            out,
            "DefaultReverseRegistrar",
            address(defaultReverseRegistrar)
        );
        vm.serializeAddress(out, "PublicResolver", address(resolver));
        vm.serializeAddress(out, "GatewayProvider", address(gatewayProvider));
        string memory json = vm.serializeAddress(
            out,
            "UniversalResolver",
            address(universalResolver)
        );
        vm.writeJson(
            json,
            string.concat("deployments/hawk-", network, ".json")
        );

        console2.log("Hawk deployed. Registry:", address(registry));
        console2.log("UniversalResolver:", address(universalResolver));
        console2.log("Controller:", address(controller));
    }

    function _deployDependencies(Config memory cfg) internal {
        usdc = cfg.usdc;
        if (usdc == address(0)) {
            usdc = address(new MockUSDC());
        }
        feed = cfg.ethUsdFeed;
        if (feed == address(0)) {
            feed = address(new MockAggregator(8, cfg.mockEthPriceUSD8));
        }
        _assertFeedDecimals(feed);
    }

    function _deployCore(Config memory cfg, address deployer) internal {
        registry = new HawkRegistry();
        registrar = new HawkBaseRegistrar(
            registry,
            HAWK_NODE,
            cfg.gracePeriod
        );
        registry.setSubnodeOwner(bytes32(0), HAWK_LABELHASH, address(registrar));

        reverseRegistrar = new ReverseRegistrar(registry);
        registry.setSubnodeOwner(bytes32(0), REVERSE_LABELHASH, deployer);
        registry.setSubnodeOwner(
            keccak256(abi.encodePacked(bytes32(0), REVERSE_LABELHASH)),
            ADDR_LABELHASH,
            address(reverseRegistrar)
        );
        defaultReverseRegistrar = new DefaultReverseRegistrar();

        reservedList = new HawkReservedList();
        uint256[] memory rates = new uint256[](5);
        rates[0] = RATE3;
        rates[1] = RATE3;
        rates[2] = RATE3;
        rates[3] = RATE4;
        rates[4] = RATE5;
        promoEnd = cfg.promoDurationSeconds == 0
            ? 0
            : block.timestamp + cfg.promoDurationSeconds;
        oracle = new HawkPriceOracle(
            AggregatorV3Interface(feed),
            cfg.maxFeedAge,
            rates,
            cfg.premiumStartAttoUSD,
            cfg.premiumDays,
            cfg.gracePeriod,
            promoEnd
        );

        wrapper = new HawkWrapper(
            registry,
            IBaseRegistrar(address(registrar)),
            IMetadataService(address(0))
        );
        registrar.addController(address(wrapper));
        metadata = new HawkMetadata(registrar, wrapper);
        wrapper.setMetadataService(IMetadataService(address(metadata)));
        registrar.setMetadataProvider(metadata);
    }

    function _deployControllerAndResolvers(
        Config memory cfg,
        address finalOwner
    ) internal {
        controller = new HawkRegistrarController(
            registrar,
            IHawkPriceOracle(address(oracle)),
            cfg.minRegistrationDuration,
            cfg.minCommitmentAge,
            cfg.maxCommitmentAge,
            IReverseRegistrar(address(reverseRegistrar)),
            IDefaultReverseRegistrar(address(defaultReverseRegistrar)),
            registry,
            IERC20Metadata(usdc),
            reservedList,
            INameWrapper(address(wrapper))
        );
        registrar.addController(address(controller));
        reverseRegistrar.setController(address(controller), true);
        defaultReverseRegistrar.setController(address(controller), true);
        wrapper.setController(address(controller), true);

        resolver = new PublicResolver(
            registry,
            INameWrapper(address(wrapper)),
            address(controller),
            address(reverseRegistrar)
        );
        reverseRegistrar.setDefaultResolver(address(resolver));

        string[] memory gatewayUrls = new string[](1);
        gatewayUrls[0] = cfg.batchGatewayUrl;
        gatewayProvider = new GatewayProvider(finalOwner, gatewayUrls);
        universalResolver = new UniversalResolver(
            finalOwner,
            registry,
            gatewayProvider
        );
    }

    /// @dev Seeds the reserved list from script/data/reserved.txt in the
    ///      same broadcast that opens registration — no sniping window.
    function _seedReservations() internal {
        string memory raw = vm.readFile("script/data/reserved.txt");
        string[] memory lines = vm.split(raw, "\n");
        string[] memory batch = new string[](80);
        uint256 n = 0;
        uint256 total = 0;
        for (uint256 i = 0; i < lines.length; i++) {
            bytes memory line = bytes(lines[i]);
            if (line.length < 3 || line[0] == "#") {
                continue;
            }
            batch[n++] = lines[i];
            total++;
            if (n == 80) {
                reservedList.setReserved(batch, true);
                batch = new string[](80);
                n = 0;
            }
        }
        if (n > 0) {
            string[] memory tail = new string[](n);
            for (uint256 i = 0; i < n; i++) {
                tail[i] = batch[i];
            }
            reservedList.setReserved(tail, true);
        }
        console2.log("reserved labels seeded:", total);
    }

    function _sanityCheck(Config memory cfg) internal view {
        require(
            registry.owner(HAWK_NODE) == address(registrar),
            "TLD not owned by registrar"
        );
        require(
            oracle.GRACE_PERIOD() == registrar.GRACE_PERIOD(),
            "grace mismatch"
        );
        require(registrar.controllers(address(controller)), "controller unwired");
        require(registrar.controllers(address(wrapper)), "wrapper unwired");
        require(
            wrapper.controllers(address(controller)),
            "wrapper controller unwired"
        );
        IPriceOracle.Price memory quote = controller.rentPriceUSDC(
            "abcde",
            365 days
        );
        uint256 expected = cfg.promoDurationSeconds == 0
            ? 5_000_000
            : 2_500_000;
        require(quote.base == expected, "USDC quote sanity failed");
        require(!controller.available("base"), "reserved seeding failed");
        require(!controller.available("coinbase"), "reserved seeding failed");
    }

    function _handover(address finalOwner, address deployer) internal {
        if (finalOwner == deployer) {
            return;
        }
        registrar.transferOwnership(finalOwner);
        controller.transferOwnership(finalOwner);
        wrapper.transferOwnership(finalOwner);
        reservedList.transferOwnership(finalOwner);
        reverseRegistrar.transferOwnership(finalOwner);
        defaultReverseRegistrar.transferOwnership(finalOwner);
        registry.setOwner(
            keccak256(abi.encodePacked(bytes32(0), REVERSE_LABELHASH)),
            finalOwner
        );
        registry.setOwner(bytes32(0), finalOwner);
    }

    function _readConfig(
        string memory network
    ) internal view returns (Config memory cfg) {
        string memory json = vm.readFile(
            string.concat("script/config/", network, ".json")
        );
        cfg.usdc = vm.parseJsonAddress(json, ".usdc");
        cfg.ethUsdFeed = vm.parseJsonAddress(json, ".ethUsdFeed");
        cfg.mockEthPriceUSD8 = vm.parseJsonInt(json, ".mockEthPriceUSD8");
        cfg.gracePeriod = vm.parseJsonUint(json, ".gracePeriod");
        cfg.minRegistrationDuration = vm.parseJsonUint(
            json,
            ".minRegistrationDuration"
        );
        cfg.maxFeedAge = vm.parseJsonUint(json, ".maxFeedAge");
        cfg.minCommitmentAge = vm.parseJsonUint(json, ".minCommitmentAge");
        cfg.maxCommitmentAge = vm.parseJsonUint(json, ".maxCommitmentAge");
        cfg.premiumStartAttoUSD = vm.parseJsonUint(
            json,
            ".premiumStartAttoUSD"
        );
        cfg.premiumDays = vm.parseJsonUint(json, ".premiumDays");
        cfg.promoDurationSeconds = vm.parseJsonUint(
            json,
            ".promoDurationSeconds"
        );
        cfg.batchGatewayUrl = vm.parseJsonString(json, ".batchGatewayUrl");
        cfg.finalOwner = vm.parseJsonAddress(json, ".finalOwner");
        cfg.isMainnet = vm.parseJsonBool(json, ".isMainnet");
    }

    function _assertFeedDecimals(address feed) internal view {
        (bool ok, bytes memory ret) = feed.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        require(
            ok && abi.decode(ret, (uint8)) == 8,
            "feed must have 8 decimals"
        );
    }
}
