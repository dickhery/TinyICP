import Array "mo:core@1/Array";
import Blob "mo:core@1/Blob";
import Iter "mo:core@1/Iter";
import Nat "mo:core@1/Nat";
import Nat8 "mo:core@1/Nat8";
import Nat64 "mo:core@1/Nat64";
import Principal "mo:core@1/Principal";
import Result "mo:core@1/Result";
import Char "mo:core@1/Char";
import Text "mo:core@1/Text";

module {
  public let ledgerCanisterId = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
  public let ledger : Ledger = actor ("ryjl3-tyaaa-aaaaa-aaaba-cai");
  public let transferFeeE8s : Nat = 10_000;
  public let tinyUrlPriceE8s : Nat = 100_000_000;
  public let treasuryAccountIdHex = "91cfa92ae9d2cb6f5fe0db77f7017dff6c3f86ccca2fdf564d1348b56347be18";

  public type Tokens = { e8s : Nat64 };
  public type TransferArgs = {
    memo : Nat64;
    amount : Tokens;
    fee : Tokens;
    from_subaccount : ?Blob;
    to : Blob;
    created_at_time : ?{ timestamp_nanos : Nat64 };
  };
  public type TransferError = {
    #BadFee : { expected_fee : Tokens };
    #InsufficientFunds : { balance : Tokens };
    #TxTooOld : { allowed_window_nanos : Nat64 };
    #TxCreatedInFuture;
    #TxDuplicate : { duplicate_of : Nat64 };
  };
  public type TransferResult = { #Ok : Nat64; #Err : TransferError };
  public type AccountBalanceArgs = { account : Blob };
  public type Ledger = actor {
    account_balance_dfx : shared query AccountBalanceArgs -> async Tokens;
    transfer : shared TransferArgs -> async TransferResult;
  };
  public type WalletInfo = {
    canisterPrincipal : Principal;
    depositAccountId : Text;
    subaccountHex : Text;
    balanceE8s : Nat;
    transferFeeE8s : Nat;
    tinyUrlPriceE8s : Nat;
  };

  public func subaccountForPrincipal(user : Principal) : Blob {
    let bytes = Blob.toArray(Principal.toBlob(user));
    let output = Array.tabulateVar<Nat8>(32, func _ = 0);
    output[0] := Nat8.fromNat(bytes.size());
    for (i in bytes.keys()) {
      if (i + 1 < 32) {
        output[i + 1] := bytes[i];
      };
    };
    Blob.fromArrayMut(output);
  };

  public func accountIdForUser(canisterPrincipal : Principal, user : Principal) : Blob {
    Principal.toLedgerAccount(canisterPrincipal, ?subaccountForPrincipal(user));
  };

  public func accountIdHexForUser(canisterPrincipal : Principal, user : Principal) : Text {
    toHex(accountIdForUser(canisterPrincipal, user));
  };

  public func toHex(blob : Blob) : Text {
    Blob.toArray(blob)
    |> Iter.map<Nat8, Text>(_, byteToHex)
    |> Iter.toArray(_)
    |> Text.join("", _);
  };

  public func fromHex(text : Text) : Result.Result<Blob, Text> {
    if (text.size() != 64) {
      return #err("Account identifiers must be 64 hexadecimal characters.");
    };

    let chars = text.chars() |> Iter.toArray(_);
    let bytes = Array.tabulateVar<Nat8>(32, func _ = 0);
    var i = 0;
    var j = 0;

    while (i < chars.size()) {
      let ?high = hexValue(chars[i]) else return #err("Invalid hexadecimal account identifier.");
      let ?low = hexValue(chars[i + 1]) else return #err("Invalid hexadecimal account identifier.");
      bytes[j] := Nat8.fromNat(high * 16 + low);
      i += 2;
      j += 1;
    };

    #ok(Blob.fromArrayMut(bytes));
  };

  public func destinationToAccountIdentifier(destination : Text) : Result.Result<Blob, Text> {
    if (destination.size() == 64) {
      return fromHex(destination);
    };

    try {
      let principal = Principal.fromText(destination);
      #ok(Principal.toLedgerAccount(principal, null));
    } catch (_) {
      #err("Destination must be either a principal ID or a 64-character account identifier.");
    };
  };

  public func transferFromSubaccount(args : {
    fromSubaccount : Blob;
    to : Blob;
    amountE8s : Nat;
    memo : Nat64;
  }) : async Result.Result<Nat64, Text> {
    let result = await ledger.transfer({
      memo = args.memo;
      amount = { e8s = Nat64.fromNat(args.amountE8s) };
      fee = { e8s = Nat64.fromNat(transferFeeE8s) };
      from_subaccount = ?args.fromSubaccount;
      to = args.to;
      created_at_time = null;
    });

    switch (result) {
      case (#Ok(blockIndex)) #ok(blockIndex);
      case (#Err(error)) #err(transferErrorMessage(error));
    };
  };

  public func getWalletInfo(canisterPrincipal : Principal, user : Principal) : async WalletInfo {
    let account = accountIdForUser(canisterPrincipal, user);
    let balance = await ledger.account_balance_dfx({ account });
    {
      canisterPrincipal;
      depositAccountId = toHex(account);
      subaccountHex = toHex(subaccountForPrincipal(user));
      balanceE8s = Nat64.toNat(balance.e8s);
      transferFeeE8s;
      tinyUrlPriceE8s;
    };
  };

  func transferErrorMessage(error : TransferError) : Text {
    switch (error) {
      case (#BadFee({ expected_fee })) {
        "Ledger fee mismatch. Expected fee: " # Nat.toText(Nat64.toNat(expected_fee.e8s)) # " e8s.";
      };
      case (#InsufficientFunds({ balance })) {
        "Insufficient wallet balance. Current balance: " # Nat.toText(Nat64.toNat(balance.e8s)) # " e8s.";
      };
      case (#TxTooOld(_)) { "Transfer request is too old." };
      case (#TxCreatedInFuture) { "Transfer request was created in the future." };
      case (#TxDuplicate({ duplicate_of })) {
        "Duplicate transfer detected at block " # Nat.toText(Nat64.toNat(duplicate_of)) # ".";
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
};
