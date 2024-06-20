// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract dTSLA is ConfirmedOwner,FunctionsClient,ERC20{
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;
    error dTsla__notEnoughCollateral();
    error dTsla__DoesntMeetMinimumWithdrawalAmount();
    error transferFailed();

    // MATH CONSTANTS
    uint256 constant PRECISION = 1e18;
    uint256 constant ADITIONAL_FEED_PRECISION = 1e10;
    uint256 constant COLLATERAL_RATIO = 200;
    uint256 constant COLLATERAL_PRECISION = 100;

    enum minOrRedeem{mint, redeem}

    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        minOrRedeem mintOrRedeem;
    }

    string private s_mintSourceCode;
    string private s_redeemSourceCode;
    uint256 private s_portfolioBalance;
    address constant SEPOLIA_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    address constant SEPOLIA_TSLA_PRICE_FEED = 0xc59E3633BAAC79493d908e63626716e204A45EdF;
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant SEPOLIA_USDC = 0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87;
    bytes32 constant don_id = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;
    uint256 public constant MINIMUM_REDEMPTION_COIN_REDEMPTION_AMOUNT = 100e18;
    uint32 constant gas_limit = 300_000;
    uint64 immutable i_subID;

    mapping(bytes32 requestID => dTslaRequest request) private s_requestIdToRequest; 
    mapping (address user => uint256 pendingWithdrawalAmount) private s_userToWithdrawAmount;

    constructor
        (
        string memory mintSourceCode,
        string memory redeemSourceCode, 
        uint64 subID
        ) 
    ConfirmedOwner(msg.sender)
    FunctionsClient(SEPOLIA_FUNCTIONS_ROUTER)
    ERC20("dTsla","dTSLA")
    {
        s_mintSourceCode = mintSourceCode;
        s_redeemSourceCode = redeemSourceCode;
        i_subID = subID;
    }

    function sendMintRequest(uint256 amount) external onlyOwner returns(bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSourceCode);
        bytes32 requestID = _sendRequest(req.encodeCBOR(), i_subID, gas_limit, don_id);
        s_requestIdToRequest[requestID] = dTslaRequest(amount,msg.sender,minOrRedeem.mint);
        return requestID;
    }

    function _mintFullfillRequest(bytes32 requestID,bytes memory response) internal{
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestID].amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));
        if(_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance){
            revert dTsla__notEnoughCollateral();
        }
        if (amountOfTokensToMint != 0){
            _mint(s_requestIdToRequest[requestID].requester, amountOfTokensToMint);
        }
    }

    function sendRedeemRequest(uint256 amountdTsla) external{
        uint256 amountTslaInUsd = getUsdcValueofUsd(getUsdcValueofTsla(amountdTsla));

        if(amountTslaInUsd < MINIMUM_REDEMPTION_COIN_REDEMPTION_AMOUNT){
            revert dTsla__DoesntMeetMinimumWithdrawalAmount();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode); // Initialize the request with JS code
        string[] memory args = new string[](2);
        args[0] = amountdTsla.toString();
        // The transaction will fail if it's outside of 2% slippage
        // This could be a future improvement to make the slippage a parameter by someone
        args[1] = amountTslaInUsd.toString();
        req.setArgs(args);
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode);
        bytes32 requestID = _sendRequest(req.encodeCBOR(), i_subID, gas_limit, don_id);
        s_requestIdToRequest[requestID] = dTslaRequest(amountdTsla,msg.sender,minOrRedeem.redeem);
        _burn(msg.sender,amountdTsla);
    }

    function getUsdcValueofUsd(uint256 usdAmount) public view returns(uint256){
        return (usdAmount * getUsdcPrice()) / PRECISION;
    }

    function getUsdcValueofTsla(uint256 tslaAmount) public view returns(uint256){
        return (tslaAmount * getTslaPrice()) / PRECISION;
    }

    function _redeemFulfillRequest(bytes32 requestID,bytes memory response) internal{
        uint usdcAmount = uint256(bytes32(response));
        if (usdcAmount == 0){
            uint256 amountofdTSLABurned = s_requestIdToRequest[requestID].amountOfToken;
            _mint(s_requestIdToRequest[requestID].requester,amountofdTSLABurned);
        }
        s_userToWithdrawAmount[s_requestIdToRequest[requestID].requester] += usdcAmount;
    }

    function withDraw() external {
        uint256 amountToWithdraw = s_userToWithdrawAmount[msg.sender];
        s_userToWithdrawAmount[msg.sender] = 0;
        bool success = ERC20(0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87).transfer(msg.sender, amountToWithdraw);
        if(!success){
            revert transferFailed();
        }
    }

    function fulfillRequest(bytes32 requestID,bytes memory response,bytes memory /*err*/) internal override {
        if (s_requestIdToRequest[requestID].mintOrRedeem == minOrRedeem.mint){
            _mintFullfillRequest(requestID,response);
        }
        else{
            _redeemFulfillRequest(requestID,response);
        }
    }

    function _getCollateralRatioAdjustedTotalBalance(uint256 amountOfTokensToMint) internal view returns(uint) {
        uint calculateNewTotalValue = getCalculatedNewTotalValue(amountOfTokensToMint);
        return (calculateNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION;
    }

    function getCalculatedNewTotalValue(uint256 addedNumberofTokens) internal view returns(uint256){
        return ((totalSupply() + addedNumberofTokens) * getTslaPrice()) / PRECISION;
    }

    function getTslaPrice() public view returns (uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_TSLA_PRICE_FEED);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return uint256(price) * ADITIONAL_FEED_PRECISION;
        }

        function getUsdcPrice() public view returns(uint256){
            AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_USDC_PRICE_FEED);
            (,int256 price,,,) = priceFeed.latestRoundData();
            return uint256(price) * ADITIONAL_FEED_PRECISION;
        }

        // view functions //

        function getRequest(bytes32 requestID) public view returns(dTslaRequest memory){
            return s_requestIdToRequest[requestID];
        }
}