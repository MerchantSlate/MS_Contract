// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20 {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);
}

interface SpotValue {
    function getRate(
        address srcToken,
        address dstToken,
        bool useWrappers
    ) external view returns (uint256 weightedRate);
}

contract MerchantSlate {
    // Error Messages
    // ERROR_TASK_IN_PROGRESS
    // ERROR_NOT_AUTHORISED
    // ERROR_INVALID_INPUTS
    // ERROR_INVALID_TOKEN
    // ERROR_LOW_FUNDS
    // ERROR_OUT_OF_STOCK
    // ERROR_APPROVE_MISSING

    struct TokenData {
        address add;
        string name;
        string symbol;
        uint8 decimals;
    }

    struct Product {
        uint256 id;
        uint256 amount; // value of the product
        uint256 qty; // Product quantity (optional)
        bool qtyCap; // Product quantity is capped
        TokenData token; // token used for payment
    }

    struct Payment {
        uint256 id;
        uint256 time; // Time of payment
        uint256 prod; // Global product ID
        address buyer; // Address of the buyer
        TokenData token; // Address of payment token
        uint256 amount; // amount paid per product
        uint256 qty; // quantity of products
        uint256 paid; // Amount paid to the merchant (after commission and fees)
        uint256 comm; // Commission amount
    }

    // Text strings repeated in compiled code
    string private constant NATIVE = "NATIVE";
    string private constant ERROR_TASK_IN_PROGRESS = "ERROR_TASK_IN_PROGRESS";

    // constants
    uint256 public constant FeeDenom = 1e3; // Fee denominator, result 0.1%
    uint256 public constant TotalStakes = 30; // Maximum total stakes limit
    uint256 public constant ProductFee = 1e15; // Fee for adding a product (0.001 ether in wei)
    uint256 public constant MerchantFee = 1e16; // Merchant signup fee (0.01 ether)

    // internal
    uint256 private baseId; // Counter for productId starting from
    uint256 private newOfferId; // offer Id counter to assign unique offer IDs
    uint256 private newPayId; // Global master payment ID counter (start from 1)
    uint256 private newProdId; // Counter for productId starting from
    uint256 private newMerchantId; // Counter for merchant IDs starting from 1
    bool private inProgress; // Lock flag for reentrancy guard
    SpotValue private valueAggregator; // Value oracle

    // arrays
    address[] private stakeHolderAddresses; // To keep track of all stake holders addresses
    uint256[] private paymentIds; // Array to store master payment IDs for pagination
    uint256[] private stakeOffers; // Array to track all offer IDs

    // public
    uint256 public totalFeesPaid; // Total fees paid to stake holders for valuation
    mapping(uint256 productId => Product) public productDetails; // global productId => Product details

    // mapping
    mapping(address => uint256) private stakeHolders; // Mapping for stake holders addresses to stake
    mapping(uint256 => address) private productMerchant; // global productId => Product details
    mapping(uint256 => address) private commissionAdd; // global productId => commission addresses
    mapping(uint256 => uint256) private commissionPer; // global productId => commission percentage
    mapping(uint256 => uint256[]) private merchantProducts; // merchantId => list of merchant product IDs
    mapping(uint256 => uint256[]) private merchantPayments; // merchantId => list of merchant payment IDs
    mapping(address => uint256[]) private buyerPayments; // buyer address => list of buyers payments
    mapping(uint256 => Payment) private payments; // global payment Id => Payment details
    mapping(address => uint256) private merchantPaymentCounters; // merchant => payment ID counter
    mapping(address => uint256) private merchants; // Mapping to store merchant details by address
    mapping(uint256 => address) private stakeOfferOwners; // Mapping to track listed stakes by offerId
    mapping(uint256 => uint256) private stakeValues; // Mapping to track listed stakes by offerId

    // buyer address => list of buyers payments to a specific merchant
    mapping(address => mapping(uint256 => uint256[]))
        private buyerToMerchantPayments;

    // Payment event of buyer and product Id
    event PaymentReceived(
        uint256 indexed productId,
        uint256 indexed quantity,
        address indexed buyer
    );

    constructor() {
        // Values
        // ref https://portal.1inch.dev/documentation/contracts/spot-price-aggregator/introduction
        valueAggregator = SpotValue(
            address(0x0AdDd25a91563696D8567Df78D5A01C9a991F9B8)
        );

        // Counters
        baseId = block.number; // Start counter from current timestamp
        newOfferId = baseId;
        newPayId = baseId;
        newProdId = baseId;
        newMerchantId = baseId;

        // stake holders
        stakeHolders[msg.sender] = TotalStakes; // Owner as first stake holder
        stakeHolderAddresses.push(msg.sender); // Add owner to stake holders list
    }

    // Ensure that reentrancy protection is active by checking if inProgress is false
    modifier progressCheck() {
        require(!inProgress, ERROR_TASK_IN_PROGRESS);
        inProgress = true; // Mark the start of the critical section
        _; // Execute the function
        inProgress = false; // Mark the end of the critical section
    }

    function _authorised(bool valid) internal pure {
        require(valid, "ERROR_NOT_AUTHORISED");
    }

    function _inputValid(bool valid) internal pure {
        require(valid, "ERROR_INVALID_INPUTS");
    }

    function _fundsEnough(bool valid) internal pure {
        require(valid, "ERROR_LOW_FUNDS");
    }

    function _onlyMerchant() internal view {
        _authorised(merchants[msg.sender] != 0);
    }

    // Check message value
    function _valueEnough(uint256 amount) internal view {
        _fundsEnough(msg.value >= amount);
    }

    // Product ID is valid
    function _isProduct(uint256 productId) internal view {
        _inputValid(productDetails[productId].amount > 0);
    }

    function _onlyStakeHolders() internal view {
        _authorised(stakeHolders[msg.sender] > 0);
    }

    // Check if token address has a contract and if token has value
    function _validToken(address token) internal view {
        if (token != address(0)) {
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(token)
            }
            require(
                codeSize != 0 || _convert(token, 1e6, address(0)) > 0,
                "ERROR_INVALID_TOKEN"
            );
        }
    }

    // Return excess amount to sender
    function returnExcess(
        uint256 providedAmount,
        uint256 targetAmount
    ) internal {
        uint256 excessAmount = providedAmount - targetAmount;
        if (excessAmount > 0) payable(msg.sender).transfer(excessAmount);
    }

    // Merchant signs up by paying a signup fee
    function merchantSignup() external payable progressCheck returns (uint256) {
        // initial validation
        _authorised(merchants[msg.sender] == 0);
        _valueEnough(MerchantFee);

        // assign id
        newMerchantId++; // Increment Merchant Id
        merchants[msg.sender] = newMerchantId; // Store Merchant Id
        divideFee(msg.value, address(0));
        returnExcess(msg.value, MerchantFee);
        return newMerchantId; // Return Merchant Id
    }

    // Check Merchant Id
    function getMerchantId() public view returns (uint256) {
        // initial validation
        _onlyMerchant();
        return merchants[msg.sender];
    }

    // Generate new product Id
    function _newProductId() internal returns (uint256) {
        newProdId++; // Increment the product IDs
        productMerchant[newProdId] = msg.sender;
        merchantProducts[merchants[msg.sender]].push(newProdId);
        return newProdId;
    }

    // Get token data
    function _tokenData(
        address tokenAddress
    ) internal view returns (TokenData memory) {
        // initial validation
        _validToken(tokenAddress);
        if (tokenAddress != address(0)) {
            IERC20 token = IERC20(tokenAddress);
            return
                TokenData({
                    add: tokenAddress,
                    name: token.name(),
                    symbol: token.symbol(),
                    decimals: token.decimals()
                });
        } else {
            return
                TokenData({
                    add: address(0),
                    name: NATIVE,
                    symbol: NATIVE,
                    decimals: 18
                });
        }
    }

    // Token Data
    function getTokenData(
        address tokenAddress
    ) external view returns (TokenData memory) {
        return _tokenData(tokenAddress);
    }

    // Convert token to native value
    function _convert(
        address tokenAddress,
        uint256 amount,
        address referenceAddress
    ) internal view returns (uint256) {
        if (tokenAddress == referenceAddress) return amount;
        uint256 rate;
        try
            valueAggregator.getRate(referenceAddress, tokenAddress, true)
        returns (uint256 response) {
            rate = response; // Success case
        } catch {
            rate = 0;
        }
        return rate > 0 ? ((1e18 * amount) / rate) : 0;
    }

    // Convert token to native value
    function tokenRate(
        address tokenAddress,
        uint256 amount,
        address referenceAddress
    ) external view returns (uint256) {
        return _convert(tokenAddress, amount, referenceAddress);
    }

    // Add a new product and become a merchant if not already
    function _productUpdate(
        address tokenAddress,
        uint256 amount,
        address commAdd,
        uint256 commPer, // 0 --> 100
        uint256 qty,
        uint256 productId
    ) internal progressCheck returns (uint256) {
        // initial validation
        _onlyMerchant();
        _validToken(tokenAddress);

        // data validation
        bool hasCommission = commPer != 0 && commAdd != address(0);
        bool validCommission = commAdd != address(0) &&
            commPer > 0 &&
            commPer < 100;
        _inputValid(amount > 0 && (!hasCommission || validCommission));

        // product Id
        bool isNewProduct = productId == 0;
        if (isNewProduct) productId = _newProductId();

        // Record commissions if any
        if (validCommission) {
            commissionAdd[productId] = commAdd;
            commissionPer[productId] = commPer;
        }

        // Store the product globally and link to the merchant
        productDetails[productId] = Product({
            id: productId,
            token: _tokenData(tokenAddress), // token data
            amount: amount, // Set the product value
            qty: qty, // product max quantity (optional)
            qtyCap: qty != 0 // Cap quantity if it does not equal zero
        });

        // Distribute product fee to stake holders
        if (isNewProduct) {
            divideFee(ProductFee, address(0));
            returnExcess(msg.value, ProductFee);
        }

        // Return the new product ID
        return productId;
    }

    // Add a new product
    function addProduct(
        address tokenAddress,
        uint256 amount,
        address commAdd,
        uint256 commPer,
        uint256 qty
    ) external payable returns (uint256) {
        // initial validation
        _valueEnough(ProductFee);
        return _productUpdate(tokenAddress, amount, commAdd, commPer, qty, 0);
    }

    // Update an existing product
    function updateProduct(
        address token,
        uint256 amount,
        address commAdd,
        uint256 commPer,
        uint256 qty,
        uint256 productId
    ) external returns (uint256) {
        // initial validation
        _isProduct(productId);
        return _productUpdate(token, amount, commAdd, commPer, qty, productId);
    }

    // Delete Product
    function deleteProduct(
        uint256 productId
    ) external progressCheck returns (uint256) {
        // initial validation
        _onlyMerchant();
        _isProduct(productId);
        _authorised(productMerchant[productId] == msg.sender);

        // Remove product from global maps
        delete productDetails[productId];
        delete productMerchant[productId];
        delete commissionAdd[productId];
        delete commissionPer[productId];

        // Remove the product ID from the merchantProducts array efficiently
        uint256 merchantId = merchants[msg.sender];
        uint256[] storage merchantProductList = merchantProducts[merchantId];
        for (uint256 i = 0; i < merchantProductList.length; i++) {
            if (merchantProductList[i] == productId) {
                // Shift elements to the left to maintain order
                for (uint256 j = i; j < merchantProductList.length - 1; j++) {
                    merchantProductList[j] = merchantProductList[j + 1];
                }
                merchantProductList.pop(); // Remove the last element
                break;
            }
        }
        return productId;
    }

    // Pagination parameters
    function _pagination(
        uint256 pageNo,
        uint256 pageSize,
        uint256 totalNumber
    ) internal pure returns (bool, uint256, uint256) {
        uint256 range = pageNo * pageSize;
        uint256 end = totalNumber > range ? (totalNumber - range) : 0;
        if (totalNumber == 0 || end == 0) return (true, 0, 0);
        return (
            false,
            end,
            end - (end > pageSize ? (end - pageSize) : 0) // end - start
        );
    }

    // Get products function for all or specific merchant
    function getProducts(
        uint256 pageNo,
        uint256 pageSize,
        uint256 merchantId // Optional merchant ID to get specific merchant's products
    ) external view returns (Product[] memory, uint256 total) {
        uint256 totalProducts = merchantId == 0
            ? (newProdId - baseId) // Latest product Id
            : merchantProducts[merchantId].length; // Return the number of products for the merchant
        (bool empty, uint256 end, uint256 resultsCount) = _pagination(
            pageNo,
            pageSize,
            totalProducts
        );
        if (empty) return (new Product[](0), totalProducts);
        Product[] memory productList = new Product[](resultsCount);
        if (merchantId == 0) {
            for (uint256 i = 0; i < resultsCount; i++)
                productList[i] = productDetails[baseId + end - i];
        } else {
            uint256[] memory productIds = merchantProducts[merchantId];
            for (uint256 i = 0; i < resultsCount; i++)
                productList[i] = productDetails[productIds[end - 1 - i]];
        }
        return (productList, totalProducts);
    }

    function _payProductCalc(
        uint256 totalAmount,
        uint256 productId
    ) internal view returns (address, uint256, uint256, uint256) {
        uint256 feeAmount = totalAmount / FeeDenom; // Calculate fee based on fee factor
        uint256 merchantPaid = totalAmount - feeAmount; // merchant and commission payments

        // Check if commission address is set
        if (
            commissionPer[productId] > 0 &&
            commissionAdd[productId] != address(0)
        ) {
            uint256 commAmount = (totalAmount * commissionPer[productId]) / 100; // Calculate commission amount
            return (
                commissionAdd[productId],
                commAmount,
                merchantPaid - commAmount, // Deduct commission from merchant payment
                feeAmount
            );
        } else {
            return (address(0), 0, merchantPaid, feeAmount);
        }
    }

    // Pay for a product, handling fee and commission logic
    function payProduct(
        uint256 productId,
        uint256 quantity
    ) external payable progressCheck returns (uint256) {
        // initial validation
        _isProduct(productId);
        _inputValid(quantity > 0);

        // token
        address tokenAddress = productDetails[productId].token.add;

        // validate buyer
        uint256 totalAmount = productDetails[productId].amount * quantity;
        validateBuyer(totalAmount, tokenAddress);

        // validate and manage stock
        stockControl(productId, quantity);

        // Calculate commission and payment details
        (
            address commAdd,
            uint256 commAmount,
            uint256 merchantPaid,
            uint256 feeAmount
        ) = _payProductCalc(totalAmount, productId);

        // Transfer commission if applicable
        _tokenTransfer(commAdd, commAmount, tokenAddress);

        // Transfer the remaining payment to the merchant
        _tokenTransfer(productMerchant[productId], merchantPaid, tokenAddress);

        // Record the payment
        uint256 paymentId = recordPayment(
            productId,
            quantity,
            merchantPaid,
            commAmount
        );

        // Distribute fee to stake holders
        divideFee(feeAmount, tokenAddress);
        if (msg.value > 0) returnExcess(msg.value, totalAmount);

        return paymentId;
    }

    // Validate buyer has funds
    function validateBuyer(
        uint256 totalAmount,
        address tokenAddress
    ) internal view {
        // token payment
        if (tokenAddress != address(0)) {
            IERC20 token = IERC20(tokenAddress);
            _fundsEnough(token.balanceOf(msg.sender) >= totalAmount);
            require(
                token.allowance(msg.sender, address(this)) >= totalAmount,
                "ERROR_APPROVE_MISSING"
            );

            // native payment
        } else {
            _fundsEnough(
                msg.sender.balance >= totalAmount && msg.value >= totalAmount
            );
        }
    }

    // Control products stocks
    function stockControl(uint256 productId, uint256 quantity) internal {
        if (productDetails[productId].qtyCap) {
            require(
                productDetails[productId].qty >= quantity,
                "ERROR_OUT_OF_STOCK"
            );
            productDetails[productId].qty =
                productDetails[productId].qty -
                quantity;
        }
    }

    // Transfer token
    function _tokenTransfer(
        address to,
        uint256 amount,
        address tokenAddress
    ) internal {
        if (amount > 0 && to != address(0)) {
            if (tokenAddress != address(0)) {
                IERC20(tokenAddress).transferFrom(
                    msg.sender, // Buyer pays the fee
                    to, // stake holder address
                    amount // stake holder fee stake
                );
            } else payable(to).transfer(amount);
        }
    }

    // Record payment in contract
    function recordPayment(
        uint256 productId,
        uint256 quantity,
        uint256 merchantPaid,
        uint256 commAmount
    ) internal returns (uint256 payId) {
        // New payment Id
        newPayId++;

        address buyer = msg.sender;

        // Store payment
        payments[newPayId] = Payment({
            id: newPayId,
            time: block.timestamp,
            prod: productId,
            buyer: buyer,
            token: productDetails[productId].token,
            amount: productDetails[productId].amount,
            qty: quantity,
            paid: merchantPaid,
            comm: commAmount
        });

        // Merchant payments
        uint256 merchantId = merchants[productMerchant[productId]];
        merchantPayments[merchantId].push(newPayId);

        // Buyer payments
        buyerToMerchantPayments[buyer][merchantId].push(newPayId);
        buyerPayments[buyer].push(newPayId);

        // Global payments
        paymentIds.push(newPayId);

        // Emit payment received event
        emit PaymentReceived(productId, quantity, buyer);

        return newPayId;
    }

    // Get payments function for all or specific merchant
    function getPayments(
        uint256 pageNo,
        uint256 pageSize,
        uint256 merchantId, // Optional
        address buyer // Optional
    ) external view returns (Payment[] memory, uint256 total) {
        uint256[] memory paymentIdsList = buyer != address(0) // buyer lists
            ? merchantId == 0
                ? buyerPayments[buyer]
                : buyerToMerchantPayments[buyer][merchantId] // general lists
            : merchantId == 0
            ? paymentIds // Get the total number of payments made (pagination)
            : merchantPayments[merchantId]; // Return the total number of payments to the merchant
        uint256 totalPayments = paymentIdsList.length;
        (bool empty, uint256 end, uint256 resultsCount) = _pagination(
            pageNo,
            pageSize,
            totalPayments
        );
        if (empty) return (new Payment[](0), totalPayments);
        Payment[] memory paymentList = new Payment[](resultsCount);
        uint256 index = end - 1;
        for (uint256 i = 0; i < resultsCount; i++)
            paymentList[i] = payments[paymentIdsList[index - i]];
        return (paymentList, totalPayments);
    }

    // stake holders

    // Function to calculate stake holder fee stake
    function divideFee(uint256 totalFee, address tokenAddress) internal {
        IERC20 token; // Token contract for payment
        bool isToken = tokenAddress != address(0);

        if (isToken) token = IERC20(tokenAddress);

        for (uint256 i = 0; i < stakeHolderAddresses.length; i++) {
            uint256 transferAmount = (totalFee *
                stakeHolders[stakeHolderAddresses[i]]) / TotalStakes;
            if (isToken)
                token.transferFrom(
                    msg.sender, // Buyer pays the fee
                    stakeHolderAddresses[i], // stake holder address
                    transferAmount // stake holder fee stake
                );
            else payable(stakeHolderAddresses[i]).transfer(transferAmount);
        }
        totalFeesPaid += _convert(tokenAddress, totalFee, address(0));
    }

    // stakes offered
    function _stakesOffered()
        internal
        view
        returns (
            uint256[] memory offerIds,
            uint256[] memory offerValues,
            bool[] memory isHolderOffer,
            uint256 holderOffersCount
        )
    {
        address holderAddress = msg.sender;
        uint256[] memory values = new uint256[](stakeOffers.length);
        bool[] memory holderOffers = new bool[](stakeOffers.length);
        uint256 holderOffersTotal = 0;
        for (uint256 i = 0; i < stakeOffers.length; i++) {
            uint256 offerId = stakeOffers[i];
            values[i] = stakeValues[offerId];
            bool isThisHolder = stakeOfferOwners[offerId] == holderAddress;
            holderOffers[i] = isThisHolder;
            if (isThisHolder) holderOffersTotal++;
        }
        return (stakeOffers, values, holderOffers, holderOffersTotal);
    }

    // Get stake holder stakes
    function _stakesCount()
        internal
        view
        returns (uint256 holdings, uint256 offered)
    {
        // initial validation
        _onlyStakeHolders();
        (, , , uint256 holderOffersCount) = _stakesOffered();
        uint256 holdingsCount = stakeHolders[msg.sender] - holderOffersCount;
        return (holdingsCount, holderOffersCount);
    }

    // Get stake holder stakes
    function stakesCount()
        external
        view
        returns (uint256 holdings, uint256 offered)
    {
        return _stakesCount();
    }

    // List the stake for a specific value
    function offerStake(
        uint256 stakeUnits,
        uint256 valuePerStake
    ) external returns (uint256[] memory) {
        (uint256 holdings, ) = _stakesCount();
        _inputValid(
            stakeUnits > 0 && stakeUnits <= holdings && valuePerStake > 0
        );
        address holderAddress = msg.sender;
        uint256[] memory offerIds = new uint256[](stakeUnits);
        for (uint256 i = 0; i < stakeUnits; i++) {
            newOfferId++; // Generate a new offerId for each unit
            offerIds[i] = newOfferId; // Store the offer ID
            stakeOfferOwners[newOfferId] = holderAddress; // Create the offer entry
            stakeOffers.push(newOfferId);
            stakeValues[newOfferId] = valuePerStake;
        }

        return offerIds; // Return an array of offer IDs
    }

    // Get all offer IDs and their corresponding data
    function stakesOffered()
        external
        view
        returns (
            uint256[] memory offerIds,
            uint256[] memory offerValues,
            bool[] memory isHolderOffer,
            uint256 holderOffersCount
        )
    {
        return _stakesOffered();
    }

    // Internal function to handle stake transfers
    function _transferStake(
        address from,
        address to,
        uint256 stakeUnits
    ) internal {
        // initial validation
        _inputValid(
            to != address(0) &&
                stakeUnits > 0 &&
                stakeUnits <= stakeHolders[from]
        );

        // Transfer stake from `from` to `to`
        stakeHolders[from] -= stakeUnits;

        // Remove stake holder if their stake drops to zero
        if (stakeHolders[from] == 0) {
            for (uint256 i = 0; i < stakeHolderAddresses.length; i++) {
                if (stakeHolderAddresses[i] == from) {
                    stakeHolderAddresses[i] = stakeHolderAddresses[
                        stakeHolderAddresses.length - 1
                    ];
                    stakeHolderAddresses.pop();
                    break;
                }
            }
        }

        // Add stake to the recipient
        if (stakeHolders[to] == 0) stakeHolderAddresses.push(to);
        stakeHolders[to] += stakeUnits;
    }

    // Clear stake offer
    function _clearOfferId(uint256 offerId) internal {
        delete stakeOfferOwners[offerId];
        delete stakeValues[offerId];

        // Remove offerId from stakeOffers
        for (uint256 i = 0; i < stakeOffers.length; i++) {
            if (stakeOffers[i] == offerId) {
                stakeOffers[i] = stakeOffers[stakeOffers.length - 1];
                stakeOffers.pop();
                break;
            }
        }
    }

    // Transfer stakes from one stake holder to another
    function transferStake(
        uint256 stakeUnits,
        address recipientAddress
    ) external {
        (uint256 holdings, ) = _stakesCount();
        _inputValid(stakeUnits <= holdings);
        _transferStake(msg.sender, recipientAddress, stakeUnits);
    }

    // Remove stake offer
    function removeStakeOffer(uint256 offerId) external {
        // initial validation
        _authorised(stakeOfferOwners[offerId] == msg.sender);
        _clearOfferId(offerId);
    }

    // take a stake by offerId
    function takeStake(uint256 offerId) external payable progressCheck {
        uint256 offerValue = stakeValues[offerId];

        // initial validation
        _inputValid(offerValue > 0);
        _valueEnough(offerValue);

        // Transfer value to owner
        _tokenTransfer(stakeOfferOwners[offerId], offerValue, address(0));

        // Transfer stake to the buyer using the helper function
        _transferStake(stakeOfferOwners[offerId], msg.sender, 1);

        // Clear offer
        _clearOfferId(offerId);

        // Return excess if any
        returnExcess(msg.value, offerValue);
    }
}
