  
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-solidity/contracts/access/Ownable.sol";
import "openzeppelin-solidity/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-solidity/contracts/utils/Strings.sol";
import "./IFactoryERC1155.sol";
import "./ERC1155Tradable.sol";

/**
 * @title Item factory
 * CreatureAccessory - a factory contract for Creature Accessory semi-fungible
 * tokens.
 */
contract ItemFactory is FactoryERC1155, Ownable, ReentrancyGuard {
    using Strings for string;
    using SafeMath for uint256;

    address public proxyRegistryAddress;
    address public nftAddress;
    string
        internal constant baseMetadataURI = "https://app.babilu.online/";
    uint256 constant UINT256_MAX = ~uint256(0);

    // Number of items for this collection
    uint256 NUM_ITEM_OPTIONS = 0;

    constructor(
        address _proxyRegistryAddress,
        address _nftAddress,
        uint256 _initialItemOptionCount
    ) {
        proxyRegistryAddress = _proxyRegistryAddress;
        nftAddress = _nftAddress;
        NUM_ITEM_OPTIONS = _initialItemOptionCount;
    }

    // Add a new Item
    function addOption() public {
        require(
            _isOwnerOrProxy(_msgSender()),
            "ItemFactory#addOption: ONLY OWNER CAN ADD OPTION"
        );

        NUM_ITEM_OPTIONS = NUM_ITEM_OPTIONS + 1;
    }

    /////
    // FACTORY INTERFACE METHODS
    /////

    function name() override external pure returns (string memory) {
        return "Babilu Online Item Factory";
    }

    function symbol() override external pure returns (string memory) {
        return "BOFACTORY";
    }

    function supportsFactoryInterface() override external pure returns (bool) {
        return true;
    }

    function factorySchemaName() override external pure returns (string memory) {
        return "ERC1155";
    }

    function numOptions() override external view returns (uint256) {
        return NUM_ITEM_OPTIONS;
    }

    function uri(uint256 _optionId) override external pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    baseMetadataURI,
                    "saga-items/",
                    Strings.toString(_optionId)
                    )
                );
    }

    function canMint(uint256 _optionId, uint256 _amount)
        override
        external
        view
        returns (bool)
    {
        return _canMint(_msgSender(), _optionId, _amount);
    }

    function mint(
        uint256 _optionId,
        address _toAddress,
        uint256 _amount,
        bytes calldata _data
    ) override external nonReentrant() {
        return _mint(_optionId, _toAddress, _amount, _data);
    }

    /**
     * @dev Main minting logic implemented here!
     */
    function _mint(
        uint256 _option,
        address _toAddress,
        uint256 _amount,
        bytes memory _data
    ) internal {
        require(
            _canMint(_msgSender(), _option, _amount),
            "ItemFactory#_mint: CANNOT_MINT_MORE"
        );
        if (_option < NUM_ITEM_OPTIONS) {
            require(_isOwnerOrProxy(_msgSender()), "Caller cannot mint items");
            // LootBoxes are not premined, so we need to create or mint them.
            // lootBoxOption is used as a token ID here.
            _createOrMint(
                nftAddress,
                _toAddress,
                _option,
                _amount,
                _data
            );
        } else {
            revert("ItemFactory#_mint: Unknown _option");
        }
    }

    /*
     * Note: make sure code that calls this is non-reentrant.
     * Note: this is the token _id *within* the ERC1155 contract, not the option
     *       id from this contract.
     */
    function _createOrMint(
        address _erc1155Address,
        address _to,
        uint256 _id,
        uint256 _amount,
        bytes memory _data
    ) internal {
        ERC1155Tradable tradable = ERC1155Tradable(_erc1155Address);
        // Lazily create the token
        if (!tradable.exists(_id)) {
            tradable.create(_to, _id, _amount, "", _data);
        } else {
            tradable.mint(_to, _id, _amount, _data);
        }
    }

    /**
     * Get the factory's ownership of Option.
     * Should be the amount it can still mint.
     * NOTE: Called by `canMint`
     */
    function balanceOf(address _owner, uint256 _optionId)
        override
        public
        view
        returns (uint256)
    {
            // Only the factory owner or owner's proxy can have supply
            if (!_isOwnerOrProxy(_owner)) {
                return 0;
            }
            
            return UINT256_MAX; //Item balance is limited by the amount of items generated from the LootBoxes
    }

    function _canMint(
        address _fromAddress,
        uint256 _optionId,
        uint256 _amount
    ) internal view returns (bool) {
        if(!_isOwnerOrProxy(_fromAddress)) //Only the owner proxy can mint from the factory
            return false;
        
        return _amount > 0 && _optionId < NUM_ITEM_OPTIONS; //Item max qty unknown until 
    }

    function _isOwnerOrProxy(address _address) internal view returns (bool) {
        ProxyRegistry proxyRegistry = ProxyRegistry(proxyRegistryAddress);
        return
            owner() == _address ||
            address(proxyRegistry.proxies(owner())) == _address;
    }
}