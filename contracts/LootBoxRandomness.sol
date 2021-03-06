// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-solidity/contracts/utils/math/SafeMath.sol";

/*
  DESIGN NOTES:
  - We assume Class 0 is common!
  - Because this is a library we use a state struct rather than member
    variables. This struct is passes as the first argument to any functions that
    need it. This can make some function signatures look strange.
  - Because this is a library we cannot call owner(). We could include an owner
    field in the state struct, but this would add maintenance overhead for
    users of this library who have to make sure they change that field when
    changing the owner() of the contract that uses this library. We therefore
    append an _owner parameter to the argument list of functions that need to
    access owner(), which makes some function signatures (particularly _mint)
    look weird but is better than hiding a dependency on an easily broken
    state field.
  - We also cannot call onlyOwner or whenNotPaused. Users of this library should
    not expose any of the methods in this library, and should wrap any code that
    uses methods that set, reset, or open anything in onlyOwner().
    Code that calls _mint should also be wrapped in nonReentrant() and should
    ensure perform the equivalent checks to _canMint() in
    CreatureAccessoryFactory.
 */


/*
    Cloakd Adjustments:
    * Changed to support multiple lootboxes with differewnt class->tokens
    * Adjust minting logic to not require the items to be pre-minted



*/

abstract contract Factory {
    function mint(uint256 _optionId, address _toAddress, uint256 _amount, bytes calldata _data) virtual external;

    function balanceOf(address _owner, uint256 _optionId) virtual public view returns (uint256);
}


/**
 * @title LootBoxRandomness
 * LootBoxRandomness- support for a randomized and openable lootbox.
 */
library LootBoxRandomness {
    using SafeMath for uint256;

    // Event for logging lootbox opens
    event LootBoxOpened(uint256 indexed optionId, address indexed buyer, uint256 boxesPurchased, uint256 itemsMinted);
    event Warning(string message, address account);

    uint256 constant INVERSE_BASIS_POINT = 10000;

    // NOTE: Price of the lootbox is set via sell orders on OpenSea
    struct OptionSettings {
        bool exists;

        // Number of items to send per open.
        // Set to 0 to disable this Option.
        uint256 maxQuantityPerOpen;
        // Probability in basis points (out of 10,000) of receiving each class (descending)
        uint16[] classProbabilities;
        // Whether to enable `guarantees` below
        bool hasGuaranteedClasses;
        // Number of items you're guaranteed to get, for each class
        uint16[] guarantees;


        //Start ID of the classes for this lootbox
        uint256 classStart;
        //Number of items in this option (lootbox)
        uint256 numClasses;
    }

    struct LootBoxRandomnessState {
        address factoryAddress;
        uint256 numOptions;
        mapping(uint256 => OptionSettings) optionToSettings;
        mapping(uint256 => uint256[]) classToTokenIds;
        uint256 seed;
        uint256[] usedTokenIDs;
    }

    //////
    // INITIALIZATION FUNCTIONS FOR OWNER
    //////

    /**
     * @dev Set up the fields of the state that should have initial values.
     */
    function initState(
        LootBoxRandomnessState storage _state,
        address _factoryAddress,
        uint256 _seed
    ) public {
        _state.factoryAddress = _factoryAddress;
        _state.seed = _seed;
    }

    /**
     * Add a new lootbox option
     * Once added token classses should be assigned
     */
    function addOption(
        LootBoxRandomnessState storage _state,
        uint256 _option,
        uint256 _maxQuantityPerOpen,
        uint256 _classStartId,
        uint256 _classCount,
        uint16[] memory _classProbabilities,
        uint256[] memory _uncommonItems,
        uint256[] memory _rareItems,
        uint256[] memory _epicItems,
        uint16[] memory _guarantees) public {
        _state.numOptions = _state.numOptions + 1;
        _setOptionSettings(_state, _option, _maxQuantityPerOpen, _classStartId, _classCount, _classProbabilities, _guarantees);

        //Set token IDs for lootbox classes
        setTokenIdsForClass(_state, _option, 0, _uncommonItems);
        setTokenIdsForClass(_state, _option, 1, _rareItems);
        setTokenIdsForClass(_state, _option, 2, _epicItems);

        //Lock items to not be available
        // _state.usedTokenIDs.push(_uncommonItems);
        // _state.usedTokenIDs.push(_rareItems);
        // _state.usedTokenIDs.push(_epicItems);
    }


    /**
     * @dev Alternate way to add token ids to a class
     * Note: resets the full list for the class instead of adding each token id
     */
    function setTokenIdsForClass(
        LootBoxRandomnessState storage _state,
        uint256 _optionId,
        uint256 _classId,
        uint256[] memory _tokenIds
    ) public {

        OptionSettings memory s = _state.optionToSettings[_optionId];

        require(_classId >= s.classStart && _classId < s.classStart + s.numClasses, "_class out of range");
        _state.classToTokenIds[_classId] = _tokenIds;
    }



    /**
     * @dev Set the settings for a particular lootbox option
     * @param _option The Option to set settings for
     * @param _maxQuantityPerOpen Maximum number of items to mint per open.
     *                            Set to 0 to disable this option.
     * @param _classProbabilities Array of probabilities (basis points, so integers out of 10,000)
     *                            of receiving each class (the index in the array).
     *                            Should add up to 10k and be descending in value.
     * @param _guarantees         Array of the number of guaranteed items received for each class
     *                            (the index in the array).
     */
    function _setOptionSettings(
        LootBoxRandomnessState storage _state,
        uint256 _option,
        uint256 _maxQuantityPerOpen,
        uint256 _classStartId,
        uint256 _classCount,
        uint16[] memory _classProbabilities,
        uint16[] memory _guarantees
    ) internal {
        require(_option < _state.numOptions, "_option out of range");
        // Allow us to skip guarantees and save gas at mint time
        // if there are no classes with guarantees
        bool hasGuaranteedClasses = false;
        for (uint256 i = 0; i < _guarantees.length; i++) {
            if (_guarantees[i] > 0) {
                hasGuaranteedClasses = true;
            }
        }

        OptionSettings memory settings = OptionSettings({
            exists : true,
            maxQuantityPerOpen : _maxQuantityPerOpen,
            classProbabilities : _classProbabilities,
            hasGuaranteedClasses : hasGuaranteedClasses,
            numClasses : _classCount,
            classStart : _classStartId,
            guarantees : _guarantees
            });

        _state.optionToSettings[uint256(_option)] = settings;
    }

    /**
     * @dev Improve pseudorandom number generator by letting the owner set the seed manually,
     * making attacks more difficult
     * @param _newSeed The new seed to use for the next transaction
     */
    function setSeed(
        LootBoxRandomnessState storage _state,
        uint256 _newSeed
    ) public {
        _state.seed = _newSeed;
    }

    ///////
    // MAIN FUNCTIONS
    //////

    /**
     * @dev Main minting logic for lootboxes
     * This is called via safeTransferFrom when CreatureAccessoryLootBox extends
     * CreatureAccessoryFactory.
     * NOTE: prices and fees are determined by the sell order on OpenSea.
     * WARNING: Make sure msg.sender can mint!
     */
    function _mint(
        LootBoxRandomnessState storage _state,
        uint256 _optionId,
        address _toAddress,
        uint256 _amount,
        bytes memory /* _data */,
        address _owner
    ) internal {
        require(_optionId < _state.numOptions, "LootBoxRandomness#_mint:_option out of range");
        // Load settings for this box option
        OptionSettings memory settings = _state.optionToSettings[_optionId];
        require(settings.exists, "LootBoxRandomness#_mint: Option settings do not exist");

        require(settings.maxQuantityPerOpen > 0, "LootBoxRandomness#_mint: OPTION_NOT_ALLOWED");

        uint256 totalMinted = 0;
        // Iterate over the quantity of boxes specified
        for (uint256 i = 0; i < _amount; i++) {
            // Iterate over the box's set quantity
            uint256 quantitySent = 0;
            if (settings.hasGuaranteedClasses) {
                // Process guaranteed token ids
                for (uint256 classId = 0; classId < settings.guarantees.length; classId++) {
                    uint256 quantityOfGuaranteed = settings.guarantees[classId];
                    if (quantityOfGuaranteed > 0) {
                        _sendTokenWithClass(_state, _optionId, classId, _toAddress, quantityOfGuaranteed, _owner);
                        quantitySent += quantityOfGuaranteed;
                    }
                }
            }

            // Process non-guaranteed ids
            while (quantitySent < settings.maxQuantityPerOpen) {
                uint256 quantityOfRandomized = 1;
                uint256 class = _pickRandomClass(_state, settings.classProbabilities);
                _sendTokenWithClass(_state, _optionId, class, _toAddress, quantityOfRandomized, _owner);
                quantitySent += quantityOfRandomized;
            }

            totalMinted += quantitySent;
        }

        // Event emissions
        emit LootBoxOpened(_optionId, _toAddress, _amount, totalMinted);
    }

    /////
    // HELPER FUNCTIONS
    /////

    // Returns the tokenId sent to _toAddress
    function _sendTokenWithClass(
        LootBoxRandomnessState storage _state,
        uint256 _optionId,
        uint256 _classId,
        address _toAddress,
        uint256 _amount,
        address _owner
    ) internal returns (uint256) {
        OptionSettings memory s = _state.optionToSettings[_optionId];

        require(_classId >= s.classStart && _classId < s.classStart + s.numClasses, "_class out of range");
        Factory factory = Factory(_state.factoryAddress);
        uint256 tokenId = _pickRandomAvailableTokenIdForClass(_state, _classId, _amount, _owner);
        // This may mint, create or transfer. We don't handle that here.
        // We use tokenId as an option ID here.
        factory.mint(tokenId, _toAddress, _amount, "");
        return tokenId;
    }

    function _pickRandomClass(
        LootBoxRandomnessState storage _state,
        uint16[] memory _classProbabilities
    ) internal returns (uint256) {
        uint16 value = uint16(_random(_state).mod(INVERSE_BASIS_POINT));
        // Start at top class (length - 1)
        // skip common (0), we default to it
        for (uint256 i = _classProbabilities.length - 1; i > 0; i--) {
            uint16 probability = _classProbabilities[i];
            if (value < probability) {
                return i;
            } else {
                value = value - probability;
            }
        }
        //FIXME: assumes zero is common!
        return 0;
    }

    function _pickRandomAvailableTokenIdForClass(
        LootBoxRandomnessState storage _state,
        uint256 _classId,
        uint256 _minAmount,
        address _owner
    ) internal returns (uint256) {
        uint256[] memory tokenIds = _state.classToTokenIds[_classId];
        require(tokenIds.length > 0, "No token ids for _classId");
        uint256 randIndex = _random(_state).mod(tokenIds.length);
        // Make sure owner() owns or can mint enough
        Factory factory = Factory(_state.factoryAddress);
        for (uint256 i = randIndex; i < randIndex + tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i % tokenIds.length];
            // We use tokenId as an option id here
            if (factory.balanceOf(_owner, tokenId) >= _minAmount) {
                return tokenId;
            }
        }
        revert("LootBoxRandomness#_pickRandomAvailableTokenIdForClass: NOT_ENOUGH_TOKENS_FOR_CLASS");
    }

    /**
     * @dev Pseudo-random number generator
     * NOTE: to improve randomness, generate it with an oracle
     */
    function _random(LootBoxRandomnessState storage _state) internal returns (uint256) {
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1), msg.sender, _state.seed)));
        _state.seed = randomNumber;
        return randomNumber;
    }

    function _addTokenIdToClass(LootBoxRandomnessState storage _state, uint256 _classId, uint256 _tokenId) internal {
        // This is called by code that has already checked this, sometimes in a
        // loop, so don't pay the gas cost of checking this here.
        //require(_classId < _state.numClasses, "_class out of range");
        _state.classToTokenIds[_classId].push(_tokenId);
    }
}
