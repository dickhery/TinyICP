import Array "mo:core@1/Array";
import Blob "mo:core@1/Blob";
import Debug "mo:core@1/Debug";
import Nat "mo:core@1/Nat";
import Route "mo:liminal/Route";
import RouteContext "mo:liminal/RouteContext";
import Runtime "mo:core@1/Runtime";
import Text "mo:core@1/Text";
import Serde "mo:serde";
import UrlStore "UrlStore";

module {
  public class Router(store : UrlStore.Store) = self {
    public func getAllUrls(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      let urls = Array.map<UrlStore.Url, UrlStore.UrlView>(store.getAllUrls(), store.toView);
      routeContext.buildResponse(#ok, #content(toCandid(to_candid(urls))));
    };

    public func redirect<system>(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      let shortCode = routeContext.getRouteParam("shortCode");
      switch (store.incrementClicks(shortCode)) {
        case (null) routeContext.buildResponse(#notFound, #error(#message("Short URL not found")));
        case (?originalUrl) {
          routeContext.buildResponse(
            #found,
            #custom({
              body = Text.encodeUtf8("Redirecting to " # originalUrl);
              headers = [("Location", originalUrl), ("Cache-Control", "no-cache")];
            }),
          );
        };
      };
    };

    public func getStats(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      let shortCode = routeContext.getRouteParam("shortCode");
      switch (store.getUrlByShortCode(shortCode)) {
        case (null) routeContext.buildResponse(#notFound, #error(#message("Short URL not found")));
        case (?url) routeContext.buildResponse(#ok, #content(toCandid(to_candid(store.toView(url)))));
      };
    };

    public func createShortUrl<system>(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      routeContext.buildResponse(#forbidden, #error(#message("Authenticated dashboard payments are required to create Tiny ICP URLs.")));
    };

    public func deleteUrl<system>(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      routeContext.buildResponse(#forbidden, #error(#message("Use the authenticated dashboard to manage Tiny ICP URLs.")));
    };

    func toCandid(value : Blob) : Serde.Candid.Candid {
      let urlKeys = ["id", "originalUrl", "shortCode", "clicks", "createdAt"];
      let options : ?Serde.Options = ?{
        renameKeys = [];
        blob_contains_only_values = false;
        types = null;
        use_icrc_3_value_type = false;
      };
      switch (Serde.Candid.decode(value, urlKeys, options)) {
        case (#err(e)) {
          Debug.print("Failed to decode URL Candid. Error: " # e);
          Runtime.trap("Failed to decode URL Candid. Error: " # e);
        };
        case (#ok(candid)) {
          if (candid.size() != 1) {
            Debug.print("Invalid Candid response. Expected 1 element, got " # Nat.toText(candid.size()));
            Runtime.trap("Invalid Candid response. Expected 1 element, got " # Nat.toText(candid.size()));
          };
          candid[0];
        };
      };
    };
  };
};
