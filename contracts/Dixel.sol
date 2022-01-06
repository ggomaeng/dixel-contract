// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./lib/ColorUtils.sol";
import "./lib/Base64.sol";
import "./DixelSVGGenerator.sol";
import "./DixelArt.sol";

/**
* @title Dixel
*
* Crowd-sourced pixel art community
*/
contract Dixel is Ownable, ReentrancyGuard, DixelSVGGenerator {
    IERC20 public baseToken;
    DixelArt public nft;

    uint200 private constant GENESIS_PRICE = 1e18; // Initial price: 1 DIXEL
    uint256 private constant PRICE_INCREASE_RATE = 500; // 5% price increase on over-writing
    uint256 private constant REWARD_RATE = 1000; // 10% goes to contributors & 90% goes to NFT contract for refund on burn
    uint256 private constant MAX_RATE = 10000;

    struct Pixel {
        uint24 color; // 24bit integer (000000 - ffffff = 0 - 16777215)
        uint32 owner; // GAS_SAVING: player.id, max 42B users
        uint200 price; // GAS_SAVING
    }

    struct PixelParams {
        uint8 x;
        uint8 y;
        uint24 color;
    }

    struct Player {
        uint32 id;
        uint32 contribution;
        uint192 rewardClaimed;
        uint256 rewardDebt;
    }

    uint256 totalContribution;
    uint256 accRewardPerContribution;

    // Fancy math here:
    //   - player.rewardDebt: Reward amount that should be deducted (the amount accumulated before I joined)
    //   - accRewardPerContribution: Accumulated reward per share (contribution)
    //     (use `accRewardPerContribution * 1e18` because the value is normally less than 1 with many decimals)

    // Example: accRewardPerContribution =
    //   1. reward: 100 (+100) & total contribution: 100 -> 0 + 100 / 100 = 1.0
    //   2. reward: 150 (+50) & total contribution: 200 (+100) -> 1 + 50 / 200 = 1.25
    //   3. reward: 250 (+100) & total contribution: 230 (+30) -> 1.25 + 100 / 230 = 1.68478
    //
    //   => claimableReward = (player.contribution * accRewardPerContribution) - player.rewardDebt
    //
    // Update `accRewardPerContribution` whenever a reward added (new NFT is minted)
    //   => accRewardPerContribution += reward generated / (new)totalContribution
    //
    // Update player's `rewardDebt` whenever the player claim reward or mint a new token (contribution changed)
    //   => player.rewardDebt = accRewardPerContribution * totalContribution

    Pixel[CANVAS_SIZE][CANVAS_SIZE] public pixels;

    // GAS_SAVING: Store player's wallet addresses
    address[] public playerWallets;
    mapping(address => Player) public players;

    event UpdatePixels(address player, uint16 pixelCount, uint96 totalPrice, uint96 rewardGenerated);
    event ClaimReward(address player, uint256 amount);

    constructor(address baseTokenAddress, address dixelArtAddress) {
        baseToken = IERC20(baseTokenAddress);
        nft = DixelArt(dixelArtAddress);

        // players[0].id = baseTokenAddress (= token burning)
        playerWallets.push(baseTokenAddress);
        players[baseTokenAddress].id = 0;

        for (uint256 x = 0; x < CANVAS_SIZE; x++) {
            for (uint256 y = 0; y < CANVAS_SIZE; y++) {
                // omit initial owner because default value 0 is correct
                pixels[x][y].price = GENESIS_PRICE;
            }
        }
    }

    // Approve token spending by this contract, should be called after construction
    function initApprove() external onlyOwner {
        require(baseToken.approve(address(this), 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff), 'APPROVE_FAILED');
    }

    function _getOrAddPlayer(address wallet) private returns (Player storage) {
        require(playerWallets.length < 0xffffffff, 'MAX_USER_REACHED');

        if (players[wallet].id == 0 && wallet != playerWallets[0]) {
            playerWallets.push(wallet);
            players[wallet].id = uint32(playerWallets.length - 1);
        }

        return players[wallet];
    }

    function updatePixels(PixelParams[] calldata params, uint256 nextTokenId) external nonReentrant {
        require(params.length <= CANVAS_SIZE * CANVAS_SIZE, 'TOO_MANY_PIXELS');
        require(nextTokenId == nft.nextTokenId(), 'NFT_EDITION_NUMBER_MISMATCHED');

        address msgSender = _msgSender();
        Player storage player = _getOrAddPlayer(msgSender);

        uint256 totalPrice = 0;
        for (uint256 i = 0; i < params.length; i++) {
            Pixel storage pixel = pixels[params[i].x][params[i].y];

            pixel.color = params[i].color;
            pixel.owner = player.id;
            totalPrice += pixel.price;

            pixel.price = uint200(pixel.price + pixel.price * PRICE_INCREASE_RATE / MAX_RATE);
        }

        // 10% goes to the contributor reward pools
        uint256 reward = totalPrice * REWARD_RATE / MAX_RATE;
        require(baseToken.transferFrom(msgSender, address(this), reward), 'REWARD_TRANSFER_FAILED');

        // 90% goes to the NFT contract for refund on burn
        require(baseToken.transferFrom(msgSender, address(nft), totalPrice - reward), 'RESERVE_TRANSFER_FAILED');

        nft.mint(msgSender, getPixelColors(), uint16(params.length), uint96(totalPrice - reward));

        // Update stats for reward calculation
        uint256 pendingReward = claimableReward(msgSender);
        player.contribution += uint32(params.length);
        totalContribution += params.length;
        player.rewardDebt = accRewardPerContribution * player.contribution / 1e18 - pendingReward;

        accRewardPerContribution += 1e18 * reward / totalContribution;

        emit UpdatePixels(msgSender, uint16(params.length), uint96(totalPrice), uint96(reward));
    }

    function totalPlayerCount() external view returns (uint256) {
        return playerWallets.length;
    }

    // MARK: - Reward by contributions

    function claimableReward(address wallet) public view returns (uint256) {
        return accRewardPerContribution * players[wallet].contribution - players[wallet].rewardDebt;
    }

    function claimReward() public {
        address msgSender = _msgSender();

        uint256 amount = claimableReward(msgSender);
        require(amount > 0, 'NOTHING_TO_CLAIM');

        Player storage player = players[msgSender];
        player.rewardClaimed += uint192(amount);
        player.rewardDebt = accRewardPerContribution * player.contribution / 1e18; // claimable becomes 0

        require(baseToken.transfer(msgSender, amount), 'REWARD_TRANSFER_FAILED');

        emit ClaimReward(msgSender, amount);
    }

    // MARK: - Draw SVG

    function getPixelColors() public view returns (uint24[CANVAS_SIZE][CANVAS_SIZE] memory pixelColors) {
        for (uint256 x = 0; x < CANVAS_SIZE; x++) {
            for (uint256 y = 0; y < CANVAS_SIZE; y++) {
                pixelColors[x][y] = pixels[x][y].color;
            }
        }
    }

    function getPixelOwners() public view returns (address[CANVAS_SIZE][CANVAS_SIZE] memory pixelOwners) {
        for (uint256 x = 0; x < CANVAS_SIZE; x++) {
            for (uint256 y = 0; y < CANVAS_SIZE; y++) {
                pixelOwners[x][y] = playerWallets[pixels[x][y].owner];
            }
        }
    }

    function getPixelPrices() public view returns (uint200[CANVAS_SIZE][CANVAS_SIZE] memory pixelPrices) {
        for (uint256 x = 0; x < CANVAS_SIZE; x++) {
            for (uint256 y = 0; y < CANVAS_SIZE; y++) {
                pixelPrices[x][y] = pixels[x][y].price;
            }
        }
    }

    function generateSVG() external view returns (string memory) {
        return _generateSVG(getPixelColors());
    }

    function generateBase64SVG() external view returns (string memory) {
        return _generateBase64SVG(getPixelColors());
    }
}
