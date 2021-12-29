const { ether, constants, expectEvent, expectRevert } = require("@openzeppelin/test-helpers");
const { MAX_UINT256, ZERO_ADDRESS } = constants;
const { expect } = require("chai");
const fs = require("fs");

const Dixel = artifacts.require("DixelMock");
const DixelArt = artifacts.require("DixelArt");
const ERC20 = artifacts.require("ERC20PresetMinterPauser");

contract("Dixel", function(accounts) {
  const [ deployer, alice, bob ] = accounts;

  beforeEach(async function() {
    this.baseToken = await ERC20.new("Test Dixel", "TEST_PIXEL");
    await this.baseToken.mint(deployer, ether("10000"));
    await this.baseToken.mint(alice, ether("100"));
    await this.baseToken.mint(bob, ether("100"));

    this.nft = await DixelArt.new();
    this.dixel = await Dixel.new(this.baseToken.address, this.nft.address);
    await this.nft.transferOwnership(this.dixel.address); // Set owner as Dixel contract, so it can mint new NFTs
  });

  describe("admin features", function() {
    it("default owner should be the deployer", async function() {
      expect(await this.dixel.owner()).to.equal(deployer);
    });
  });

  describe("update", function() {
    beforeEach(async function() {
      await this.baseToken.approve(this.dixel.address, MAX_UINT256, { from: alice });
      this.receipt = await this.dixel.updatePixels([[1, 1, 16711680], [2, 0, 65280]], 0, { from: alice }); // #ff0000, #00ff00

      this.pixel1 = await this.dixel.pixels(1, 1);
      this.pixel2 = await this.dixel.pixels(2, 0);
      this.alicePlayerId = await this.dixel.players(alice);
    });

    it("should update pixel colors", async function() {
      expect(this.pixel1.color).to.be.bignumber.equal("16711680");
      expect(this.pixel2.color).to.be.bignumber.equal("65280");
    });

    it("should update owner of pixels", async function() {
      expect(this.pixel1.owner).to.be.bignumber.equal(this.alicePlayerId);
      expect(this.pixel2.owner).to.be.bignumber.equal(this.alicePlayerId);
    });

    it("should add alice into playerWallets", async function() {
      expect(await this.dixel.playerWallets(this.alicePlayerId)).to.be.bignumber.equal(alice);
    });

    it("should increase pixels prices", async function() {
      expect(this.pixel1.price).to.be.bignumber.equal(ether("1.05"));
      expect(this.pixel2.price).to.be.bignumber.equal(ether("1.05"));
    });

    it("should transfer tokens from alice", async function() {
      expect(await this.baseToken.balanceOf(alice)).to.be.bignumber.equal(ether("97.9"));
    });

    it("should transfer tokens to the base token contract (= burning)", async function() {
      expect(await this.baseToken.balanceOf(this.baseToken.address)).to.be.bignumber.equal(ether("2.1"));
    });

    it("should have 2 player count", async function() {
      expect(await this.dixel.totalPlayerCount()).to.be.bignumber.equal("2");
    });

    it("should emit UpdatePixels event", async function() {
      expectEvent(this.receipt, "UpdatePixels", {
        player: alice,
        pixelCount: '2',
        totalPrice: ether('2.1')
      });
    });

    describe("update again", function() {
      beforeEach(async function() {
        await this.baseToken.approve(this.dixel.address, MAX_UINT256, { from: bob });
        this.receipt2 = await this.dixel.updatePixels([[1, 1, 255]], 1, { from: bob }); // #0000ff

        this.pixel1 = await this.dixel.pixels(1, 1);
        this.bobPlayerId = await this.dixel.players(bob);
      });

      it("should update pixel colors", async function() {
        expect(this.pixel1.color).to.be.bignumber.equal("255");
      });

      it("should update owner of pixels", async function() {
        expect(this.pixel1.owner).to.be.bignumber.equal(this.bobPlayerId);
      });

      it("should increase pixels' price", async function() {
        expect(this.pixel1.price).to.be.bignumber.equal(ether("1.1025"));
      });

      it("should transfer tokens from bob", async function() {
        expect(await this.baseToken.balanceOf(bob)).to.be.bignumber.equal(ether("98.8975"));
      });

      it("should transfer tokens to the base token contract (= burning)", async function() {
        expect(await this.baseToken.balanceOf(this.baseToken.address)).to.be.bignumber.equal(ether("3.2025"));
      });

      it("should emit UpdatePixels event", async function() {
        expectEvent(this.receipt2, "UpdatePixels", {
          player: bob,
          pixelCount: '1',
          totalPrice: ether('1.1025')
        });
      });

      it("should have 3 player count", async function() {
        expect(await this.dixel.totalPlayerCount()).to.be.bignumber.equal("3");
      });
    });
  });

  describe("generate SVG", function() {
    beforeEach(async function() {
      await this.baseToken.approve(this.dixel.address, MAX_UINT256, { from: alice });
      await this.dixel.updatePixels([[1, 1, 16711680], [2, 0, 65280]], 0, { from: alice }); // #ff0000, #00ff00
    });

    it("should generate SVG correctly", async function() {
      const testSVG = fs.readFileSync(`${__dirname}/fixtures/test-image.svg`, 'utf8');
      expect(await this.dixel.generateSVG()).to.equal(testSVG);
    });

    it("should encode SVG into Base64 correctly", async function() {
      const testBase64 = fs.readFileSync(`${__dirname}/fixtures/test-image-base64.txt`, 'utf8');
      expect(await this.dixel.generateBase64SVG()).to.equal(testBase64);
    });
  });

  describe("generate NFT", function() {
    beforeEach(async function() {
      await this.baseToken.approve(this.dixel.address, MAX_UINT256, { from: alice });
      this.receipt = await this.dixel.updatePixels([[1, 1, 16711680], [2, 0, 65280]], 0, { from: alice }); // #ff0000, #00ff00
    });

    it('outputs last pixel status correctly', async function() {
      const pixel1 = await this.nft.pixelHistory(0, 1, 1);
      expect(pixel1).to.be.bignumber.equal("16711680");
    });

    it('outputs last pixel status correctly 2', async function() {
      const pixel2 = await this.nft.pixelHistory(0, 2, 0);
      expect(pixel2).to.be.bignumber.equal("65280");
    });

    it('outputs all last pixels from history 0', async function() {
      const pixels = await this.nft.getPixelsFor(0);

      expect(pixels[1][1]).to.be.bignumber.equal("16711680");
      expect(pixels[2][0]).to.be.bignumber.equal("65280");
      expect(pixels[2][2]).to.be.bignumber.equal("0");
    });

    it('alice should have the nft balance', async function() {
      expect(await this.nft.balanceOf(alice)).to.be.bignumber.equal("1");
    });

    it('alice should be the owner of the NFT', async function() {
      expect(await this.nft.ownerOf(0)).to.equal(alice);
    });

    it("should outputs the SVG correctly", async function() {
      const testSVG = fs.readFileSync(`${__dirname}/fixtures/test-image.svg`, 'utf8');
      expect(await this.nft.generateSVG(0)).to.equal(testSVG);
    });

    it("should outputs the SVG into Base64 correctly", async function() {
      const testBase64 = fs.readFileSync(`${__dirname}/fixtures/test-image-base64.txt`, 'utf8');
      expect(await this.nft.generateBase64SVG(0)).to.equal(testBase64);
    });

    it("should generate tokenURI in JSON format", async function() {
      const testJSON = fs.readFileSync(`${__dirname}/fixtures/test-json.json`, 'utf8');
      expect(await this.nft.generateJSON(0)).to.equal(testJSON);
    });

    it("should outputs tokenURI correctly", async function() {
      const testJSONBase64 = fs.readFileSync(`${__dirname}/fixtures/test-json-base64.txt`, 'utf8');
      expect(await this.nft.tokenURI(0)).to.equal(testJSONBase64);
    });
  });
});
