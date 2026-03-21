import Array "mo:core@1/Array";
import Blob "mo:core@1/Blob";
import Nat "mo:core@1/Nat";
import Nat8 "mo:core@1/Nat8";
import Nat64 "mo:core@1/Nat64";
import Principal "mo:core@1/Principal";
import Text "mo:core@1/Text";
import VarArray "mo:core@1/VarArray";

module {
  public let ledger : Ledger = actor ("ryjl3-tyaaa-aaaaa-aaaba-cai");
  public let transferFeeE8s : Nat = 10_000;
  public let tinyUrlPriceE8s : Nat = 100_000_000;

  public type Tokens = { e8s : Nat64 };
  public type AccountBalanceArgs = { account : Text };
  public type Ledger = actor {
    account_balance_dfx : shared query AccountBalanceArgs -> async Tokens;
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

  public func getWalletInfo(canisterPrincipal : Principal, user : Principal) : async WalletInfo {
    let account = accountIdForUser(canisterPrincipal, user);
    let depositAccountId = toHex(account);
    let balance = await ledger.account_balance_dfx({ account = depositAccountId });
    {
      canisterPrincipal;
      depositAccountId;
      subaccountHex = toHex(subaccountForPrincipal(user));
      balanceE8s = Nat64.toNat(balance.e8s);
      transferFeeE8s;
      tinyUrlPriceE8s;
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
