// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import "../registry/ENS.sol";
import "../ethregistrar/IBaseRegistrar.sol";
import "./IHawkTokenURIProvider.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title HawkBaseRegistrar
/// @notice Owns the `.hawk` TLD node and issues second-level names as
///         ERC-721 tokens ("Hawk Names", HAWK) with expiries and a grace
///         period.
///
/// @dev Copy of upstream BaseRegistrarImplementation (ens-contracts v1.7.0)
///      with the following deliberate diffs — everything else is verbatim:
///      1. GRACE_PERIOD is an immutable constructor argument instead of a
///         constant. Mainnet deploys with exactly 90 days (upstream value);
///         testnet deploys use shortened timers so the full expiry → grace →
///         premium lifecycle can be rehearsed on a live chain.
///      2. ERC-721 name/symbol are "Hawk Names"/"HAWK" (upstream: empty).
///      3. `labels` mapping + `registerWithLabel`: controllers can record the
///         plaintext label at registration so fully on-chain metadata can
///         render the name. Plain `register`/`registerOnly` remain unchanged.
///      4. `tokenURI` is implemented via a swappable IHawkTokenURIProvider
///         (owner-set), plus `contractURI` for marketplace collection
///         metadata. Upstream has no metadata implementation.
///      5. `supportsInterface` additionally reports IERC721Metadata, since
///         name/symbol/tokenURI are now meaningful.
contract HawkBaseRegistrar is ERC721, IBaseRegistrar, Ownable {
    // A map of expiry times
    mapping(uint256 => uint256) expiries;
    // The ENS registry
    ENS public ens;
    // The namehash of the TLD this registrar owns (eg, .hawk)
    bytes32 public baseNode;
    // A map of addresses that are authorised to register and renew names.
    mapping(address => bool) public controllers;
    // Hawk diff (1): immutable, set at deploy. Mainnet value: 90 days.
    uint256 public immutable GRACE_PERIOD;
    // Hawk diff (3): plaintext labels recorded at registration, keyed by
    // token id (uint256 of the labelhash). Written once; a label never
    // changes for a given hash.
    mapping(uint256 => string) public labels;
    // Hawk diff (4): renders tokenURI/contractURI. Swappable so art can be
    // improved without touching registration state.
    IHawkTokenURIProvider public metadataProvider;

    bytes4 private constant INTERFACE_META_ID =
        bytes4(keccak256("supportsInterface(bytes4)"));
    bytes4 private constant ERC721_ID =
        bytes4(
            keccak256("balanceOf(address)") ^
                keccak256("ownerOf(uint256)") ^
                keccak256("approve(address,uint256)") ^
                keccak256("getApproved(uint256)") ^
                keccak256("setApprovalForAll(address,bool)") ^
                keccak256("isApprovedForAll(address,address)") ^
                keccak256("transferFrom(address,address,uint256)") ^
                keccak256("safeTransferFrom(address,address,uint256)") ^
                keccak256("safeTransferFrom(address,address,uint256,bytes)")
        );
    bytes4 private constant RECLAIM_ID =
        bytes4(keccak256("reclaim(uint256,address)"));

    /// @notice Emitted when the metadata provider is changed.
    event MetadataProviderChanged(address provider);

    /// v2.1.3 version of _isApprovedOrOwner which calls ownerOf(tokenId) and takes grace period into consideration instead of ERC721.ownerOf(tokenId);
    /// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.1.3/contracts/token/ERC721/ERC721.sol#L187
    /// @dev Returns whether the given spender can transfer a given token ID
    /// @param spender address of the spender to query
    /// @param tokenId uint256 ID of the token to be transferred
    /// @return bool whether the msg.sender is approved for the given token ID,
    ///              is an operator of the owner, or is the owner of the token
    function _isApprovedOrOwner(
        address spender,
        uint256 tokenId
    ) internal view override returns (bool) {
        address owner = ownerOf(tokenId);
        return (spender == owner ||
            getApproved(tokenId) == spender ||
            isApprovedForAll(owner, spender));
    }

    constructor(
        ENS _ens,
        bytes32 _baseNode,
        uint256 _gracePeriod
    ) ERC721("Hawk Names", "HAWK") {
        ens = _ens;
        baseNode = _baseNode;
        GRACE_PERIOD = _gracePeriod;
    }

    modifier live() {
        require(ens.owner(baseNode) == address(this));
        _;
    }

    modifier onlyController() {
        require(controllers[msg.sender]);
        _;
    }

    /// @dev Gets the owner of the specified token ID. Names become unowned
    ///      when their registration expires.
    /// @param tokenId uint256 ID of the token to query the owner of
    /// @return address currently marked as the owner of the given token ID
    function ownerOf(
        uint256 tokenId
    ) public view override(IERC721, ERC721) returns (address) {
        require(expiries[tokenId] > block.timestamp);
        return super.ownerOf(tokenId);
    }

    // Authorises a controller, who can register and renew domains.
    function addController(address controller) external override onlyOwner {
        controllers[controller] = true;
        emit ControllerAdded(controller);
    }

    // Revoke controller permission for an address.
    function removeController(address controller) external override onlyOwner {
        controllers[controller] = false;
        emit ControllerRemoved(controller);
    }

    // Set the resolver for the TLD this registrar manages.
    function setResolver(address resolver) external override onlyOwner {
        ens.setResolver(baseNode, resolver);
    }

    // Hawk diff (4): set the tokenURI/contractURI renderer.
    function setMetadataProvider(
        IHawkTokenURIProvider provider
    ) external onlyOwner {
        metadataProvider = provider;
        emit MetadataProviderChanged(address(provider));
    }

    // Returns the expiration timestamp of the specified id.
    function nameExpires(uint256 id) external view override returns (uint256) {
        return expiries[id];
    }

    // Returns true iff the specified name is available for registration.
    function available(uint256 id) public view override returns (bool) {
        // Not available if it's registered here or in its grace period.
        return expiries[id] + GRACE_PERIOD < block.timestamp;
    }

    /// @dev Register a name.
    /// @param id The token ID (keccak256 of the label).
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    function register(
        uint256 id,
        address owner,
        uint256 duration
    ) external override returns (uint256) {
        return _register(id, owner, duration, true);
    }

    /// @dev Hawk diff (3): register a name and record its plaintext label so
    ///      on-chain metadata can render it. Registration semantics are
    ///      identical to `register`.
    /// @param label The label to register (eg, 'foo' for 'foo.hawk').
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    function registerWithLabel(
        string calldata label,
        address owner,
        uint256 duration
    ) external returns (uint256) {
        uint256 id = uint256(keccak256(bytes(label)));
        // _register enforces live + onlyController + availability.
        uint256 expiry = _register(id, owner, duration, true);
        if (bytes(labels[id]).length == 0) {
            labels[id] = label;
        }
        return expiry;
    }

    /// @dev Register a name, without modifying the registry.
    /// @param id The token ID (keccak256 of the label).
    /// @param owner The address that should own the registration.
    /// @param duration Duration in seconds for the registration.
    function registerOnly(
        uint256 id,
        address owner,
        uint256 duration
    ) external returns (uint256) {
        return _register(id, owner, duration, false);
    }

    function _register(
        uint256 id,
        address owner,
        uint256 duration,
        bool updateRegistry
    ) internal live onlyController returns (uint256) {
        require(available(id));
        require(
            block.timestamp + duration + GRACE_PERIOD >
                block.timestamp + GRACE_PERIOD
        ); // Prevent future overflow

        expiries[id] = block.timestamp + duration;
        if (_exists(id)) {
            // Name was previously owned, and expired
            _burn(id);
        }
        _mint(owner, id);
        if (updateRegistry) {
            ens.setSubnodeOwner(baseNode, bytes32(id), owner);
        }

        emit NameRegistered(id, owner, block.timestamp + duration);

        return block.timestamp + duration;
    }

    function renew(
        uint256 id,
        uint256 duration
    ) external override live onlyController returns (uint256) {
        require(expiries[id] + GRACE_PERIOD >= block.timestamp); // Name must be registered here or in grace period
        require(
            expiries[id] + duration + GRACE_PERIOD > duration + GRACE_PERIOD
        ); // Prevent future overflow

        expiries[id] += duration;
        emit NameRenewed(id, expiries[id]);
        return expiries[id];
    }

    /// @dev Reclaim ownership of a name in ENS, if you own it in the registrar.
    function reclaim(uint256 id, address owner) external override live {
        require(_isApprovedOrOwner(msg.sender, id));
        ens.setSubnodeOwner(baseNode, bytes32(id), owner);
    }

    /// @dev Hawk diff (4): fully on-chain metadata via the provider.
    ///      Returns "" until a provider is set.
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireMinted(tokenId);
        if (address(metadataProvider) == address(0)) {
            return "";
        }
        return metadataProvider.tokenURI721(tokenId);
    }

    /// @dev Hawk diff (4): collection-level metadata for marketplaces.
    function contractURI() external view returns (string memory) {
        if (address(metadataProvider) == address(0)) {
            return "";
        }
        return metadataProvider.contractURI();
    }

    function supportsInterface(
        bytes4 interfaceID
    ) public view override(ERC721, IERC165) returns (bool) {
        return
            interfaceID == INTERFACE_META_ID ||
            interfaceID == ERC721_ID ||
            interfaceID == RECLAIM_ID ||
            // Hawk diff (5): metadata is actually implemented here.
            interfaceID == type(IERC721Metadata).interfaceId;
    }
}
