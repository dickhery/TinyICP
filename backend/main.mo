import Liminal "mo:liminal";
import RouterMiddleware "mo:liminal/Middleware/Router";
import Router "mo:liminal/Router";
import UrlRouter "UrlRouter";
import UrlStore "UrlStore";
import BTree "mo:stableheapbtreemap/BTree";
import Principal "mo:core@1/Principal";
import Runtime "mo:core@1/Runtime";
import Result "mo:core@1/Result";

shared ({ caller = initializer }) persistent actor class Actor() = self {
  var urlStableData : UrlStore.StableData = {
    urls = BTree.init<Nat, UrlStore.Url>(null);
    nextId = 1;
  };

  transient var urlStore = UrlStore.Store(urlStableData);
  transient let urlRouter = UrlRouter.Router(urlStore);

  system func preupgrade() {
    urlStableData := urlStore.toStableData();
  };

  system func postupgrade() {
    urlStore := UrlStore.Store(urlStableData);
  };

  public shared query ({ caller }) func list_my_urls() : async [UrlStore.UrlView] {
    assertAuthenticated(caller);
    urlStore.getUrlsByOwner(caller);
  };

  public shared ({ caller }) func create_my_url(request : UrlStore.CreateRequest) : async Result.Result<UrlStore.UrlView, Text> {
    assertAuthenticated(caller);
    switch (urlStore.create(request, caller)) {
      case (#ok(url)) #ok(urlStore.toView(url));
      case (#err(message)) #err(message);
    };
  };

  public shared ({ caller }) func delete_my_url(id : Nat) : async Result.Result<(), Text> {
    assertAuthenticated(caller);
    urlStore.delete(id, caller);
  };

  public shared query ({ caller }) func whoami() : async Principal {
    caller;
  };

  func assertAuthenticated(caller : Principal) {
    if (Principal.isAnonymous(caller)) {
      Runtime.trap("Authentication required");
    };
  };

  transient let routerConfig : RouterMiddleware.Config = {
    prefix = null;
    identityRequirement = null;
    routes = [
      Router.getQuery("/urls", urlRouter.getAllUrls),
      Router.postUpdate("/shorten", urlRouter.createShortUrl),
      Router.deleteUpdate("/urls/{id}", urlRouter.deleteUrl),
      Router.getUpdate("/s/{shortCode}", urlRouter.redirect),
      Router.getQuery("/s/{shortCode}/stats", urlRouter.getStats),
    ];
  };

  transient let app = Liminal.App({
    middleware = [RouterMiddleware.new(routerConfig)];
    errorSerializer = Liminal.defaultJsonErrorSerializer;
    candidRepresentationNegotiator = Liminal.defaultCandidRepresentationNegotiator;
    logger = Liminal.buildDebugLogger(#info);
  });

  public query func http_request(request : Liminal.RawQueryHttpRequest) : async Liminal.RawQueryHttpResponse {
    app.http_request(request);
  };

  public func http_request_update(request : Liminal.RawUpdateHttpRequest) : async Liminal.RawUpdateHttpResponse {
    await* app.http_request_update(request);
  };
};
