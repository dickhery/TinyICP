import Array "mo:core@1/Array";
import Blob "mo:core@1/Blob";
import Char "mo:core@1/Char";
import Nat "mo:core@1/Nat";
import Nat8 "mo:core@1/Nat8";
import Nat64 "mo:core@1/Nat64";
import Principal "mo:core@1/Principal";
import Result "mo:core@1/Result";
import Text "mo:core@1/Text";
import VarArray "mo:core@1/VarArray";

module {
  public let ledger : Ledger = actor ("ryjl3-tyaaa-aaaaa-aaaba-cai");
  public let transferFeeE8s : Nat = 10_000;
  public let tinyUrlPriceE8s : Nat = 100_000_000;

  public type Tokens = { e8s : Nat64 };
  public type AccountBalanceArgs = { account : Text };
  public type TransferArgs = {
    memo : Nat64;
    amount : Tokens;
    fee : Tokens;
    from_subaccount : ?Blob;
    to : Blob;
    created_at_time : ?TimeStamp;
  };
  public type TimeStamp = { timestamp_nanos : Nat64 };
  public type TransferError = {
    #BadFee : { expected_fee : Tokens };
    #InsufficientFunds : { balance : Tokens };
    #TxTooOld : { allowed_window_nanos : Nat64 };
    #TxCreatedInFuture : Null;
    #TxDuplicate : { duplicate_of : Nat64 };
  };
  public type TransferResult = { #Ok : Nat64; #Err : TransferError };
  public type Ledger = actor {
    account_balance_dfx : shared query AccountBalanceArgs -> async Tokens;
    transfer : shared TransferArgs -> async TransferResult;
  };
  public type WalletInfo = {
    depositAccountId : Text;
    balanceE8s : Nat;
    transferFeeE8s : Nat;
    tinyUrlPriceE8s : Nat;
  };

  public func subaccountForPrincipal(user : Principal) : Blob {
    let principalBytes = Blob.toArray(Principal.toBlob(user));
    let output = VarArray.tabulate<Nat8>(32, func _ = 0);
    output[0] := Nat8.fromNat(principalBytes.size());

    for (i in principalBytes.keys()) {
      if (i + 1 < 32) {
        output[i + 1] := principalBytes[i];
      };
    };

    Blob.fromVarArray(output);
  };

  public func accountIdForUser(canisterPrincipal : Principal, user : Principal) : Blob {
    Principal.toLedgerAccount(canisterPrincipal, ?subaccountForPrincipal(user));
  };

  public func toHex(blob : Blob) : Text {
    let parts = Array.map<Nat8, Text>(Blob.toArray(blob), byteToHex);
    Text.join("", parts.values());
  };

  public func transferFromUserSubaccount(canisterPrincipal : Principal, user : Principal, destinationAccountId : Text, amountE8s : Nat) : async Result.Result<Nat64, Text> {
    if (amountE8s == 0) {
      return #err("Transfer amount must be greater than 0 ICP.");
    };

    let destination = switch (fromHex(destinationAccountId)) {
      case (#ok(accountId)) {
        if (Blob.toArray(accountId).size() != 32) {
          return #err("Destination account ID must be a 64-character hex string.");
        };
        accountId;
      };
      case (#err(message)) return #err(message);
    };

    let senderAccount = toHex(accountIdForUser(canisterPrincipal, user));
    if (Text.equal(destinationAccountId, senderAccount)) {
      return #err("Destination account ID must be different from your Tiny ICP deposit account.");
    };

    let result = await ledger.transfer({
      memo = 0;
      amount = { e8s = Nat64.fromNat(amountE8s) };
      fee = { e8s = Nat64.fromNat(transferFeeE8s) };
      from_subaccount = ?subaccountForPrincipal(user);
      to = destination;
      created_at_time = null;
    });

    switch (result) {
      case (#Ok(blockIndex)) #ok(blockIndex);
      case (#Err(error)) #err(describeTransferError(error));
    };
  };

  public func getWalletInfo(canisterPrincipal : Principal, user : Principal) : async WalletInfo {
    let account = accountIdForUser(canisterPrincipal, user);
    let depositAccountId = toHex(account);
    let balance = await ledger.account_balance_dfx({ account = depositAccountId });
    {
      depositAccountId;
      balanceE8s = Nat64.toNat(balance.e8s);
      transferFeeE8s;
      tinyUrlPriceE8s;
    };
  };

  func fromHex(value : Text) : Result.Result<Blob, Text> {
    let chars = Text.toArray(value);
    if (chars.size() == 0 or chars.size() % 2 != 0) {
      return #err("Destination account ID must be a 64-character hex string.");
    };

    let bytes = VarArray.tabulate<Nat8>(chars.size() / 2, func _ = 0);
    var index = 0;
    while (index < chars.size()) {
      let hi = switch (hexValue(chars[index])) {
        case (?digit) digit;
        case null return #err("Destination account ID must only use hexadecimal characters.");
      };
      let lo = switch (hexValue(chars[index + 1])) {
        case (?digit) digit;
        case null return #err("Destination account ID must only use hexadecimal characters.");
      };
      bytes[index / 2] := Nat8.fromNat((hi * 16) + lo);
      index += 2;
    };

    #ok(Blob.fromVarArray(bytes));
  };

  func hexValue(char : Char) : ?Nat {
    switch (char) {
      case ('0') ?0;
      case ('1') ?1;
      case ('2') ?2;
      case ('3') ?3;
      case ('4') ?4;
      case ('5') ?5;
      case ('6') ?6;
      case ('7') ?7;
      case ('8') ?8;
      case ('9') ?9;
      case ('a' or 'A') ?10;
      case ('b' or 'B') ?11;
      case ('c' or 'C') ?12;
      case ('d' or 'D') ?13;
      case ('e' or 'E') ?14;
      case ('f' or 'F') ?15;
      case _ null;
    };
  };

  func describeTransferError(error : TransferError) : Text {
    switch (error) {
      case (#BadFee { expected_fee }) {
        "Transfer fee changed. Expected fee: " # Nat.toText(Nat64.toNat(expected_fee.e8s)) # " e8s.";
      };
      case (#InsufficientFunds { balance }) {
        "Insufficient funds. Current wallet balance: " # Nat.toText(Nat64.toNat(balance.e8s)) # " e8s.";
      };
      case (#TxTooOld _) "Transfer request expired before the ledger accepted it. Please try again.";
      case (#TxCreatedInFuture _) "Transfer request was created in the future. Please try again in a moment.";
      case (#TxDuplicate { duplicate_of }) {
        "This transfer was already submitted in ledger block " # Nat64.toText(duplicate_of) # ".";
      };
    };
  };

  func byteToHex(byte : Nat8) : Text {
    let symbols = [
      "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
    ];
    let value = Nat8.toNat(byte);
    symbols[value / 16] # symbols[value % 16];
  };
};
