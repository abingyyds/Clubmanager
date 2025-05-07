// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// Token Based Access Error Codes
error TA1(); // No admin permission
error TA2(); // Club not initialized
error TA3(); // Club already initialized
error TA4(); // Invalid token address
error TA5(); // Invalid threshold
error TA6(); // Invalid account address
error TA7(); // Invalid domain name
error TA8(); // Insufficient permissions
error TA9(); // Chain name is empty
error TA10(); // Contract is paused

// Define membership check interface
interface IMembershipQuery {
    /**
     * @dev Check if user has membership (unified interface)
     * @param domainName Club domain name
     * @param account User address
     * @return Whether has membership
     */
    function hasActiveMembership(string memory domainName, address account) external view returns (bool);
    
    // Compatible interface - maps to same implementation
    function hasActiveMembershipByDomain(string memory domainName, address account) external view returns (bool);
    function hasAccessByDomain(string memory domainName, address user) external view returns (bool);
}

// DefineClubManager interface
interface IClubManager {
    function updateMembership(address user, string memory domainName, bool status) external returns (bool);
    function isClubInitialized(string memory domainName) external view returns (bool);
    function getClubAdmin(string memory domainName) external view returns (address);
}

/**
 * @title TokenBasedAccess
 * @dev Access control contract based on token holdings
 */
contract TokenBasedAccess is IMembershipQuery, Ownable, Pausable {
    using Strings for uint256;

    address public clubManager;
    
    // Domain to ClubAdmin mapping
    mapping(string => address) private _clubAdmins;
    
    // Domain initialization status
    mapping(string => bool) private _initialized;
    
    // Token type enumeration
    enum TokenType { ERC20, ERC721, ERC1155, CROSSCHAIN }
    
    // Token threshold structure
    struct TokenGate {
        address tokenAddress;     // Local contract address (for cross-chain tokens, address(0))
        uint256 threshold;        // Required amount
        uint256 tokenId;          // ERC1155 tokenId
        TokenType tokenType;      // Token type
        string chainId;           // Chain ID (local chain is "local")
        string tokenSymbol;       // Token symbol
        string crossChainAddress; // Cross-chain address (only valid for cross-chain tokens)
        uint256 timestamp;        // Creation time
    }
    
    // Domain token threshold mapping
    mapping(string => TokenGate[]) private _domainTokenGates;
    
    // Events
    event ClubInitialized(string domainName, address admin);
    event ClubUninitialized(string domainName);
    event AdminUpdated(string domainName, address newAdmin);
    event TokenGateAdded(string domainName, address tokenAddress, uint256 threshold, uint8 tokenType);
    event ERC1155TokenGateAdded(string domainName, address tokenAddress, uint256 tokenId, uint256 threshold);
    event CrossChainTokenGateAdded(string domainName, string chainId, string tokenAddress, string tokenSymbol, uint256 threshold);
    event TokenGateRemoved(string domainName, uint256 gateIndex);
    
    constructor(address _clubManager) Ownable(msg.sender) {
        if (_clubManager == address(0)) revert TA4();
        clubManager = _clubManager;
    }
    
    /**
     * @dev Standardize domain name format
     */
    function standardizeDomainName(string memory domainName) public pure returns (string memory) {
        bytes memory domainBytes = bytes(domainName);
        
        // If empty, return empty
        if (domainBytes.length == 0) return "";
        
        // Remove .web3.club suffix (if exists)
        string memory result = _removeSuffix(domainName);
        domainBytes = bytes(result);
        
        if (domainBytes.length == 0) return "";
        
        // Simple validation of characters in domain name
        for (uint i = 0; i < domainBytes.length; i++) {
            bytes1 b = domainBytes[i];
            
            // Allow a-z, 0-9, _ characters
            if (!(
                (b >= 0x61 && b <= 0x7A) || // a-z
                (b >= 0x30 && b <= 0x39) || // 0-9
                b == 0x5F                    // _
            )) {
                return ""; // Return empty if invalid
            }
        }
        
        // Domain name valid, return prefix
        return result;
    }
    
    /**
     * @dev Remove domain name .web3.club suffix
     */
    function _removeSuffix(string memory fullDomain) internal pure returns (string memory) {
        bytes memory domainBytes = bytes(fullDomain);
        
        // Check .web3.club suffix
        string memory suffix = ".web3.club";
        bytes memory suffixBytes = bytes(suffix);
        
        if (domainBytes.length <= suffixBytes.length) {
            return fullDomain; // Too short to contain suffix
        }
        
        // Check if it ends with .web3.club
        bool hasSuffix = true;
        for (uint i = 0; i < suffixBytes.length; i++) {
            if (domainBytes[domainBytes.length - suffixBytes.length + i] != suffixBytes[i]) {
                hasSuffix = false;
                break;
            }
        }
        
        if (hasSuffix) {
            // Remove suffix
            bytes memory prefixBytes = new bytes(domainBytes.length - suffixBytes.length);
            for (uint i = 0; i < prefixBytes.length; i++) {
                prefixBytes[i] = domainBytes[i];
            }
            return string(prefixBytes);
        } else {
            // No suffix, return directly
            return fullDomain;
        }
    }
    
    // ===== Pause functionality =====
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ===== Access control modifier =====
    
    modifier onlyClubAdmin(string memory domainName) {
        string memory standardized = standardizeDomainName(domainName);
        if (msg.sender != _clubAdmins[standardized] && msg.sender != owner()) revert TA1();
        _;
    }
    
    modifier whenInitialized(string memory domainName) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_initialized[standardized]) revert TA2();
        _;
    }
    
    modifier whenNotInitialized(string memory domainName) {
        string memory standardized = standardizeDomainName(domainName);
        if (_initialized[standardized]) revert TA3();
        _;
    }
    
    modifier whenNotPaused2() {
        if (paused()) revert TA10();
        _;
    }
    
    // ===== Domain management =====
    
    /**
     * @dev Initialize club
     */
    function initializeClub(string memory domainName, address admin) external whenNotPaused2 whenNotInitialized(domainName) {
        if (admin == address(0)) revert TA6();
        
        string memory standardized = standardizeDomainName(domainName);
        if (bytes(standardized).length == 0) revert TA7();
        
        _initialized[standardized] = true;
        _clubAdmins[standardized] = admin;
        
        emit ClubInitialized(standardized, admin);
    }
    
    /**
     * @dev Initialize club (compatible with ClubManager interface)
     */
    function initializeClub(
        string memory domainName, 
        address admin, 
        string memory /* name */, 
        string memory /* symbol */, 
        string memory /* baseURI */
    ) external whenNotPaused2 whenNotInitialized(domainName) {
        if (admin == address(0)) revert TA6();
        
        string memory standardized = standardizeDomainName(domainName);
        if (bytes(standardized).length == 0) revert TA7();
        
        _initialized[standardized] = true;
        _clubAdmins[standardized] = admin;
        
        emit ClubInitialized(standardized, admin);
    }
    
    /**
     * @dev Uninitialize domain
     */
    function uninitializeClub(string memory domainName) external whenNotPaused2 whenInitialized(domainName) {
        if (msg.sender != clubManager && msg.sender != owner()) revert TA8();
        
        string memory standardized = standardizeDomainName(domainName);
        _initialized[standardized] = false;
        delete _clubAdmins[standardized];
        delete _domainTokenGates[standardized];
        
        emit ClubUninitialized(standardized);
    }
    
    /**
     * @dev Update admin
     */
    function updateClubAdmin(string memory domainName, address newAdmin) external whenNotPaused2 whenInitialized(domainName) {
        if (msg.sender != clubManager && msg.sender != owner()) revert TA8();
        if (newAdmin == address(0)) revert TA6();
        
        string memory standardized = standardizeDomainName(domainName);
        _clubAdmins[standardized] = newAdmin;
        
        emit AdminUpdated(standardized, newAdmin);
    }
    
    /**
     * @dev Check if domain is initialized
     */
    function isClubInitialized(string memory domainName) external view returns (bool initialized, address admin) {
        string memory standardized = standardizeDomainName(domainName);
        return (_initialized[standardized], _clubAdmins[standardized]);
    }
    
    /**
     * @dev Get domain admin
     */
    function getClubAdmin(string memory domainName) external view returns (address) {
        string memory standardized = standardizeDomainName(domainName);
        return _clubAdmins[standardized];
    }
    
    // ===== Token threshold management =====
    
    /**
     * @dev Add ERC20 token threshold
     */
    function addTokenGate(string memory domainName, address tokenAddress, uint256 threshold) external onlyClubAdmin(domainName) whenNotPaused whenInitialized(domainName) returns (bool) {
        if (tokenAddress == address(0)) revert TA4();
        if (threshold == 0) revert TA5();
        
        string memory standardized = standardizeDomainName(domainName);
        
        // Get token symbol
        string memory tokenSymbol = "Unknown";
        try IERC20Metadata(tokenAddress).symbol() returns (string memory symbol) {
            tokenSymbol = symbol;
        } catch {}
        
        // Create token threshold
        TokenGate memory gate = TokenGate({
            tokenAddress: tokenAddress,
            threshold: threshold,
            tokenId: 0,
            tokenType: TokenType.ERC20,
            chainId: "local",
            tokenSymbol: tokenSymbol,
            crossChainAddress: "",
            timestamp: block.timestamp
        });
        
        // Add to domain threshold list
        _domainTokenGates[standardized].push(gate);
        
        emit TokenGateAdded(standardized, tokenAddress, threshold, uint8(TokenType.ERC20));
        
        return true;
    }
    
    /**
     * @dev Add ERC721 NFT threshold
     */
    function addNFTGate(string memory domainName, address nftContract, uint256 requiredAmount) external onlyClubAdmin(domainName) whenNotPaused whenInitialized(domainName) returns (bool) {
        if (nftContract == address(0)) revert TA4();
        if (requiredAmount == 0) revert TA5();
        
        string memory standardized = standardizeDomainName(domainName);
        
        // Create NFT threshold
        TokenGate memory gate = TokenGate({
            tokenAddress: nftContract,
            threshold: requiredAmount,
            tokenId: 0,
            tokenType: TokenType.ERC721,
            chainId: "local",
            tokenSymbol: "NFT",
            crossChainAddress: "",
            timestamp: block.timestamp
        });
        
        // Add to domain threshold list
        _domainTokenGates[standardized].push(gate);
        
        emit TokenGateAdded(standardized, nftContract, requiredAmount, uint8(TokenType.ERC721));
        
        return true;
    }
    
    /**
     * @dev Add ERC1155 NFT threshold
     */
    function addERC1155Gate(
        string memory domainName, 
        address nftContract, 
        uint256 tokenId, 
        uint256 requiredAmount
    ) external onlyClubAdmin(domainName) whenNotPaused whenInitialized(domainName) returns (bool) {
        if (nftContract == address(0)) revert TA4();
        if (requiredAmount == 0) revert TA5();
        
        string memory standardized = standardizeDomainName(domainName);
        
        // Create ERC1155 threshold
        TokenGate memory gate = TokenGate({
            tokenAddress: nftContract,
            threshold: requiredAmount,
            tokenId: tokenId,
            tokenType: TokenType.ERC1155,
            chainId: "local",
            tokenSymbol: "ERC1155",
            crossChainAddress: "",
            timestamp: block.timestamp
        });
        
        // Add to domain threshold list
        _domainTokenGates[standardized].push(gate);
        
        emit ERC1155TokenGateAdded(standardized, nftContract, tokenId, requiredAmount);
        
        return true;
    }
    
    /**
     * @dev Add cross-chain token threshold
     */
    function addCrossChainTokenGate(
        string memory domainName,
        string memory chainId,
        string memory tokenAddress,
        string memory tokenSymbol,
        uint256 threshold
    ) external onlyClubAdmin(domainName) whenNotPaused whenInitialized(domainName) {
        if (bytes(chainId).length == 0) revert TA9();
        if (bytes(tokenAddress).length == 0) revert TA4();
        if (threshold == 0) revert TA5();
        
        string memory standardized = standardizeDomainName(domainName);
        
        // Create cross-chain token threshold
        TokenGate memory gate = TokenGate({
            tokenAddress: address(0),
            threshold: threshold,
            tokenId: 0,
            tokenType: TokenType.CROSSCHAIN,
            chainId: chainId,
            tokenSymbol: tokenSymbol,
            crossChainAddress: tokenAddress,
            timestamp: block.timestamp
        });
        
        // Add to domain threshold list
        _domainTokenGates[standardized].push(gate);
        
        emit CrossChainTokenGateAdded(standardized, chainId, tokenAddress, tokenSymbol, threshold);
    }
    
    /**
     * @dev Remove token threshold
     */
    function removeTokenGate(string memory domainName, uint256 gateIndex) external onlyClubAdmin(domainName) whenNotPaused whenInitialized(domainName) {
        string memory standardized = standardizeDomainName(domainName);
        
        // Check if index is valid
        require(gateIndex < _domainTokenGates[standardized].length, "Invalid gate index");
        
        // Remove threshold (by moving last element to delete position, then delete last element)
        uint256 lastIndex = _domainTokenGates[standardized].length - 1;
        if (gateIndex != lastIndex) {
            _domainTokenGates[standardized][gateIndex] = _domainTokenGates[standardized][lastIndex];
        }
        _domainTokenGates[standardized].pop();
        
        emit TokenGateRemoved(standardized, gateIndex);
    }
    
    /**
     * @dev Get all token thresholds for domain
     */
    function getTokenGates(string memory domainName) external view returns (
        address[] memory tokenAddresses,
        uint256[] memory thresholds,
        uint256[] memory tokenIds,
        uint8[] memory tokenTypes,
        string[] memory chainIds,
        string[] memory tokenSymbols,
        string[] memory crossChainAddresses
    ) {
        string memory standardized = standardizeDomainName(domainName);
        TokenGate[] storage gates = _domainTokenGates[standardized];
        uint256 length = gates.length;
        
        tokenAddresses = new address[](length);
        thresholds = new uint256[](length);
        tokenIds = new uint256[](length);
        tokenTypes = new uint8[](length);
        chainIds = new string[](length);
        tokenSymbols = new string[](length);
        crossChainAddresses = new string[](length);
        
        for (uint256 i = 0; i < length; i++) {
            TokenGate storage gate = gates[i];
            tokenAddresses[i] = gate.tokenAddress;
            thresholds[i] = gate.threshold;
            tokenIds[i] = gate.tokenId;
            tokenTypes[i] = uint8(gate.tokenType);
            chainIds[i] = gate.chainId;
            tokenSymbols[i] = gate.tokenSymbol;
            crossChainAddresses[i] = gate.crossChainAddress;
        }
    }
    
    /**
     * @dev Get token threshold count for domain
     */
    function getTokenGateCount(string memory domainName) external view returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        return _domainTokenGates[standardized].length;
    }
    
    /**
     * @dev Get specific token threshold details
     */
    function getTokenGateDetails(string memory domainName, uint256 gateIndex) external view returns (
        address tokenAddress,
        uint256 threshold,
        uint256 tokenId,
        uint8 tokenType,
        string memory chainId,
        string memory tokenSymbol,
        string memory crossChainAddress
    ) {
        string memory standardized = standardizeDomainName(domainName);
        require(gateIndex < _domainTokenGates[standardized].length, "Invalid gate index");
        
        TokenGate storage gate = _domainTokenGates[standardized][gateIndex];
        return (
            gate.tokenAddress,
            gate.threshold,
            gate.tokenId,
            uint8(gate.tokenType),
            gate.chainId,
            gate.tokenSymbol,
            gate.crossChainAddress
        );
    }
    
    // ===== Membership check =====
    
    /**
     * @dev Core function: Check if user has membership (based on real-time token holding)
     */
    function hasActiveMembership(string memory domainName, address account) public view override returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        
        // If club is not initialized, return false
        if (!_initialized[standardized]) return false;
        
        // Check all token thresholds on local chain
        TokenGate[] storage gates = _domainTokenGates[standardized];
        for (uint256 i = 0; i < gates.length; i++) {
            TokenGate storage gate = gates[i];
            
            // Skip cross-chain tokens (manual verification needed)
            if (gate.tokenType == TokenType.CROSSCHAIN) continue;
            
            // Check balance based on token type
            if (gate.tokenType == TokenType.ERC20) {
                // ERC20 check
                try IERC20(gate.tokenAddress).balanceOf(account) returns (uint256 balance) {
                    if (balance >= gate.threshold) {
                        return true;
                    }
                } catch {}
            } 
            else if (gate.tokenType == TokenType.ERC721) {
                // ERC721 check
                try IERC721(gate.tokenAddress).balanceOf(account) returns (uint256 balance) {
                    if (balance >= gate.threshold) {
                        return true;
                    }
                } catch {}
            }
            else if (gate.tokenType == TokenType.ERC1155) {
                // ERC1155 check
                try IERC1155(gate.tokenAddress).balanceOf(account, gate.tokenId) returns (uint256 balance) {
                    if (balance >= gate.threshold) {
                        return true;
                    }
                } catch {}
            }
        }
        
        // No threshold met
        return false;
    }
    
    /**
     * @dev Compatible interface - points to hasActiveMembership and synchronizes to CM
     */
    function hasActiveMembershipByDomain(string memory domainName, address account) external view override returns (bool) {
        return hasActiveMembership(domainName, account);
    }
    
    /**
     * @dev Compatible interface - points to hasActiveMembership and synchronizes to CM
     */
    function hasAccessByDomain(string memory domainName, address user) external view override returns (bool) {
        return hasActiveMembership(domainName, user);
    }
    
    /**
     * @dev Check and synchronize membership status to ClubManager
     * This function allows external calls to update CM membership record
     */
    function syncMembershipToClubManager(string memory domainName, address user) external whenNotPaused whenInitialized(domainName) returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        
        // Check current membership status
        bool hasMembership = hasActiveMembership(standardized, user);
        
        // Synchronize to ClubManager
        if (clubManager != address(0)) {
            IClubManager(clubManager).updateMembership(user, standardized, hasMembership);
        }
        
        return hasMembership;
    }
    
    /**
     * @dev Batch synchronize multiple users membership status to ClubManager
     */
    function batchSyncMembership(string memory domainName, address[] calldata users) external whenNotPaused whenInitialized(domainName) returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        
        // ClubManager not available, return directly
        if (clubManager == address(0)) return false;
        
        // Batch synchronize
        for (uint256 i = 0; i < users.length; i++) {
            bool hasMembership = hasActiveMembership(standardized, users[i]);
            IClubManager(clubManager).updateMembership(users[i], standardized, hasMembership);
        }
        
        return true;
    }
    
    /**
     * @dev Helper function: Convert address to string
     */
    function addressToString(address _addr) internal pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(_addr);
        bytes memory stringBytes = new bytes(42);
        
        stringBytes[0] = '0';
        stringBytes[1] = 'x';
        
        for (uint i = 0; i < 20; i++) {
            bytes1 leftNibble = bytes1(uint8(uint(uint8(addressBytes[i])) / 16 + 48));
            bytes1 rightNibble = bytes1(uint8(uint(uint8(addressBytes[i])) % 16 + 48));
            if (uint8(leftNibble) > 57) leftNibble = bytes1(uint8(leftNibble) + 39);
            if (uint8(rightNibble) > 57) rightNibble = bytes1(uint8(rightNibble) + 39);
            stringBytes[2+i*2] = leftNibble;
            stringBytes[2+i*2+1] = rightNibble;
        }
        
        return string(stringBytes);
    }
    
    /**
     * @dev Set ClubManager address
     */
    function setClubManager(address _clubManager) external onlyOwner {
        require(_clubManager != address(0), "Zero address not allowed");
        clubManager = _clubManager;
    }
}