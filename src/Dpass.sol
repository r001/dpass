pragma solidity ^0.5.11;

// /**
//  * How to use dapp and openzeppelin-solidity https://github.com/dapphub/dapp/issues/70
//  * ERC-721 standart: https://github.com/ethereum/EIPs/blob/master/EIPS/eip-721.md
//  *
//  */

import "ds-auth/auth.sol";
import "openzeppelin-solidity/token/ERC721/ERC721Full.sol";


contract DpassEvents {
    event LogDiamondMinted(
        address owner,
        uint indexed tokenId,
        bytes32 issuer,
        bytes32 report,
        bytes32 state
    );

    event LogAsmChanged(address asm);
    event LogStateChanged(uint indexed tokenId, bytes32 state);
    event LogSale(uint indexed tokenId);
    event LogRedeem(uint indexed tokenId);
    event LogSetAttributeNameListAddress(address priceFeed);
    event LogSetTrustedAssetManagement(address asm);
    event LogHashingAlgorithmChange(bytes8 name);
    event LogDiamondAttributesHashChange(uint indexed tokenId, bytes8 hashAlgorithm);
    event LogCustodianChanged(uint tokenId, address custodian);
    event CustodianRedFlag(address custodian, bool redFlag);
}


contract Dpass is DSAuth, ERC721Full, DpassEvents {
    string private _name = "Diamond Passport";
    string private _symbol = "Dpass";

    address public asm;                          // Asset Management contract

    struct Diamond {
        bytes32 issuer;
        bytes32 report;
        bytes32 state;
        bytes32[] attributeValues;                              // List of Rapaport calc required attributes values
        bytes8 currentHashingAlgorithm;                         // Current hashing algorithm to check in the proof mapping
    }
    Diamond[] diamonds;                                         // List of Dpasses

    mapping(uint => address) public custodian;                   // custodian that holds a Dpass token
    mapping (uint => mapping(bytes32 => bytes32)) public proof;  // Prof of attributes integrity [tokenId][hasningAlgorithm] => hash
    mapping (bytes32 => mapping (bytes32 => bool)) diamondIndex; // List of dpasses by issuer and report number [issuer][number]
    mapping (uint256 => uint256) public recreated;               // List of recreated tokens. old tokenId => new tokenId

    constructor () public ERC721Full(_name, _symbol) {
        // Create dummy diamond to start real diamond minting from 1
        Diamond memory _diamond = Diamond({
            issuer: "Self",
            report: "0",
            state: "invalid",
            attributeValues: new bytes32[](1),
            currentHashingAlgorithm: ""
        });

        diamonds.push(_diamond);
        _mint(address(this), 0);
    }

    modifier onlyOwnerOf(uint _tokenId) {
        require(ownerOf(_tokenId) == msg.sender, "Access denied");
        _;
    }

    modifier ifExist(uint _tokenId) {
        require(_exists(_tokenId), "Diamond does not exist");
        _;
    }

    modifier onlyValid(uint _tokenId) {
        // TODO: DRY, _exists already check
        require(_exists(_tokenId), "Diamond does not exist");

        Diamond storage _diamond = diamonds[_tokenId];
        require(_diamond.state != "invalid", "Diamond is invalid");
        _;
    }

    /**
    * @dev Custom accessor to create a unique token
    * @param _to address of diamond owner
    * @param _issuer string the issuer agency name
    * @param _report string the issuer agency unique Nr.
    * @param _state diamond state, "sale" is the init status
    * @param _attributes diamond Rapaport attributes
    * @param _currentHashingAlgorithm name of hasning algorithm (ex. 20190101)
    * @param _custodian the custodian of minted dpass
    * @return Return Diamond tokenId of the diamonds list
    */
    function mintDiamondTo(
        address _to,
        address _custodian,
        bytes32 _issuer,
        bytes32 _report,
        bytes32 _state,
        bytes32[] memory _attributes,
        bytes32 _attributesHash,
        bytes8 _currentHashingAlgorithm
    )
        public auth
        returns(uint)
    {
        _addToDiamondIndex(_issuer, _report);

        Diamond memory _diamond = Diamond({
            issuer: _issuer,
            report: _report,
            state: _state,
            attributeValues: _attributes,
            currentHashingAlgorithm: _currentHashingAlgorithm
        });
        uint _tokenId = diamonds.push(_diamond) - 1;
        proof[_tokenId][_currentHashingAlgorithm] = _attributesHash;
        custodian[_tokenId] = _custodian;

        _mint(_to, _tokenId);
        emit LogDiamondMinted(_to, _tokenId, _issuer, _report, _state);
        return _tokenId;
    }

    /**
    * @dev Custom accessor to create a unique token
    * @param _issuer string the issuer agency name
    * @param _report string the issuer agency unique Nr.
    * @param _state diamond state, "sale" is the init status
    * @param _attributes diamond Rapaport attributes
    * @param _currentHashingAlgorithm name of hasning algorithm (ex. 20190101)
    * @param _custodian the custodian of minted dpass
    * @return Return Diamond tokenId of the diamonds list
    */
    function mintDiamondToAsm(
        address _custodian,
        bytes32 _issuer,
        bytes32 _report,
        bytes32 _state,
        bytes32[] memory _attributes,
        bytes32 _attributesHash,
        bytes8 _currentHashingAlgorithm
    )
        public auth
        returns(uint)
    {
        mintDiamondTo(
            asm,
            _custodian,
            _issuer,
            _report,
            _state,
            _attributes,
            _attributesHash,
            _currentHashingAlgorithm);
    }

    /**
    * @dev Update _tokenId attributes
    * @param _attributesHash new attibutes hash value
    * @param _currentHashingAlgorithm name of hasning algorithm (ex. 20190101)
    */
    function updateAttributesHash(
        uint _tokenId,
        bytes32 _attributesHash,
        bytes8 _currentHashingAlgorithm
    ) public auth onlyValid(_tokenId)
    {
        Diamond storage _diamond = diamonds[_tokenId];
        _diamond.currentHashingAlgorithm = _currentHashingAlgorithm;

        proof[_tokenId][_currentHashingAlgorithm] = _attributesHash;

        emit LogDiamondAttributesHashChange(_tokenId, _currentHashingAlgorithm);
    }

    /**
    * @dev Link old and the same new dpass
    */
    function linkOldToNewToken(uint _tokenId, uint _newTokenId) public auth {
        require(_exists(_tokenId), "Old diamond does not exist");
        require(_exists(_newTokenId), "New diamond does not exist");
        recreated[_tokenId] = _newTokenId;
    }

    /**
     * @dev Transfers the ownership of a given token ID to another address
     * Usage of this method is discouraged, use `safeTransferFrom` whenever possible
     * Requires the msg.sender to be the owner, approved, or operator and not invalid token
     * @param _from current owner of the token
     * @param _to address to receive the ownership of the given token ID
     * @param _tokenId uint256 ID of the token to be transferred
     */
    function transferFrom(address _from, address _to, uint256 _tokenId) public onlyValid(_tokenId) {
        _checkTransfer(_tokenId);
        super.transferFrom(_from, _to, _tokenId);
    }

    /*
    * @dev Check if transferPossible
    */
    function _checkTransfer(uint256 _tokenId) internal view {
        bytes32 state = diamonds[_tokenId].state;

        require(state != "removed", "Token has been removed");
        require(state != "invalid", "Token deleted");
    }

    /**
     * @dev Safely transfers the ownership of a given token ID to another address
     * If the target address is a contract, it must implement `onERC721Received`,
     * which is called upon a safe transfer, and return the magic value
     * `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`; otherwise,
     * the transfer is reverted.
     * Requires the msg.sender to be the owner, approved, or operator
     * @param _from current owner of the token
     * @param _to address to receive the ownership of the given token ID
     * @param _tokenId uint256 ID of the token to be transferred
     */
    function safeTransferFrom(address _from, address _to, uint256 _tokenId) public {
        _checkTransfer(_tokenId);
        super.safeTransferFrom(_from, _to, _tokenId);
    }

    /*
    * @dev Returns the current state of diamond
    */
    function getState(uint _tokenId) public view ifExist(_tokenId) returns (bytes32) {
        return diamonds[_tokenId].state;
    }
                                                         
    /**
     * @dev Gets the Diamond at a given _tokenId of all the diamonds in this contract
     * Reverts if the _tokenId is greater or equal to the total number of diamonds
     * @param _tokenId uint representing the index to be accessed of the diamonds list
     * @return Returns all the relevant information about a specific diamond
     */
    function getDiamond(uint _tokenId)
        public
        view
        ifExist(_tokenId)
        returns (
            bytes32 issuer,
            bytes32 report,
            bytes32 state,
            bytes32[] memory attributeValues,
            bytes32 attributesHash
        )
    {
        Diamond storage _diamond = diamonds[_tokenId];
        attributesHash = proof[_tokenId][_diamond.currentHashingAlgorithm];

        return (
            _diamond.issuer,
            _diamond.report,
            _diamond.state,
            _diamond.attributeValues,
            attributesHash
        );
    }

    /**
     * @dev Gets the Diamond issuer and it unique nr at a given _tokenId of all the diamonds in this contract
     * Reverts if the _tokenId is greater or equal to the total number of diamonds
     * @param _tokenId uint representing the index to be accessed of the diamonds list
     * @return Issuer and unique Nr. a specific diamond
     */
    function getDiamondIssuerAndReport(uint _tokenId) public view ifExist(_tokenId) returns(bytes32, bytes32) {
        Diamond storage _diamond = diamonds[_tokenId];
        return (_diamond.issuer, _diamond.report);
    }

    /**
     * @dev Set new custodian for dpass
     */
    function setCustodian(uint _tokenId, address _newCustodian) public auth {
        require(_newCustodian != address(0), "Wrong address");
        custodian[_tokenId] = _newCustodian;
        emit LogCustodianChanged(_tokenId, _newCustodian);
    }

    /**
     * @dev Set asset management contract
     */
    function setAsm(address _asm) public auth {
        require(_asm != address(0), "Wrong address");
        asm = _asm;
        emit LogAsmChanged(_asm);
    }

    /**
    * @dev Get the custodian of Dpass.
    */
    function getCustodian(uint _tokenId) public view returns(address) {
        return custodian[_tokenId];
    }

    /**
     * @dev Set Diamond sale status
     * Reverts if the _tokenId is greater or equal to the total number of diamonds
     * @param _tokenId uint representing the index to be accessed of the diamonds list
     */
    function setSaleStatus(uint _tokenId) public ifExist(_tokenId) onlyOwnerOf(_tokenId) {
        _changeStateTo("sale", _tokenId);
        emit LogSale(_tokenId);
    }

    /**
     * @dev Set Diamond invalid status
     * @param _tokenId uint representing the index to be accessed of the diamonds list
     */
    function setInvalidStatus(uint _tokenId) public ifExist(_tokenId) onlyOwnerOf(_tokenId) {
        _changeStateTo("invalid", _tokenId);
        _removeDiamondFromIndex(_tokenId);
    }

    /**
     * @dev Make diamond status as redeemed, change owner to contract owner
     * Reverts if the _tokenId is greater or equal to the total number of diamonds
     * @param _tokenId uint representing the index to be accessed of the diamonds list
     */
    function redeem(uint _tokenId) public ifExist(_tokenId) onlyOwnerOf(_tokenId) {
        _changeStateTo("redeemed", _tokenId);
        // TODO: move to safeTransfer?
        transferFrom(msg.sender, owner, _tokenId);
        emit LogRedeem(_tokenId);
    }

    /**
     * @dev Change diamond status.
     * @param _newState new token state
     * @param _tokenId represent the index of diamond
     */
    function changeStateTo(bytes32 _newState, uint _tokenId) public auth ifExist(_tokenId) {
        _changeStateTo(_newState, _tokenId);
    }

    // Private functions

    /**
     * @dev Validate transiton from currentState to newState. Revert on invalid transition
     * @param _currentState current diamond state
     * @param _newState new diamond state
     */
    function _validateStateTransitionTo(bytes32 _currentState, bytes32 _newState) internal pure {
        require(_currentState != _newState, "Already in that state");
    }

    /**
     * @dev Add Issuer and report with validation to uniqueness. Revert on invalid existance
     * @param _issuer issuer like GIA
     * @param _report issuer unique nr.
     */
    function _addToDiamondIndex(bytes32 _issuer, bytes32 _report) internal {
        require(!diamondIndex[_issuer][_report], "Issuer and report not unique.");
        diamondIndex[_issuer][_report] = true;
    }

    function _removeDiamondFromIndex(uint _tokenId) internal {
        Diamond storage _diamond = diamonds[_tokenId];
        diamondIndex[_diamond.issuer][_diamond.report] = false;
    }

    /**
     * @dev Change diamond status with logging. Revert on invalid transition
     * @param _newState new token state
     * @param _tokenId represent the index of diamond
     */
    function _changeStateTo(bytes32 _newState, uint _tokenId) internal {
        Diamond storage _diamond = diamonds[_tokenId];
        _validateStateTransitionTo(_diamond.state, _newState);
        _diamond.state = _newState;
        emit LogStateChanged(_tokenId, _newState);
    }
}
