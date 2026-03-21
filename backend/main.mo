import Liminal "mo:liminal";
import RouterMiddleware "mo:liminal/Middleware/Router";
import Router "mo:liminal/Router";
import IcpLedger "IcpLedger";
import UrlRouter "UrlRouter";
import UrlStore "UrlStore";
import BTree "mo:stableheapbtreemap/BTree";
import Principal "mo:core@1/Principal";
import Runtime "mo:core@1/Runtime";
import Result "mo:core@1/Result";
import Blob "mo:core@1/Blob";
import Text "mo:core@1/Text";
import Iter "mo:core@1/Iter";
import Char "mo:core@1/Char";
import Nat64 "mo:core@1/Nat64";
import Error "mo:base/Error";
import ExperimentalCycles "mo:base/ExperimentalCycles";

shared ({ caller = initializer }) persistent actor class Actor() = self {
  type HeaderField = (Text, Text);
  type HttpRequestArgs = {
    url : Text;
    max_response_bytes : ?Nat64;
    headers : [HeaderField];
    body : ?Blob;
    method : { #get; #head; #post };
    transform : ?TransformContext;
  };
  type HttpResponsePayload = {
    status : Nat;
    headers : [HeaderField];
    body : Blob;
  };
  type TransformContext = {
    function : shared query TransformArgs -> async HttpResponsePayload;
    context : Blob;
  };
  type TransformArgs = { response : HttpResponsePayload; context : Blob };

  let ic : actor {
    http_request : HttpRequestArgs -> async HttpResponsePayload;
  } = actor ("aaaaa-aa");

  var urlStableData : UrlStore.StableData = {
    urls = BTree.init<Nat, UrlStore.Url>(null);
    nextId = 1;
  };

  transient var urlStore = UrlStore.Store(urlStableData);
  transient var urlRouter = UrlRouter.Router(urlStore);
  transient let canisterPrincipal = Principal.fromActor(self);

  system func preupgrade() {
    urlStableData := urlStore.toStableData();
  };

  system func postupgrade() {
    urlStore := UrlStore.Store(urlStableData);
    urlRouter := UrlRouter.Router(urlStore);
    routerConfig := buildRouterConfig();
    app := buildApp(routerConfig);
  };

  public shared query ({ caller }) func list_my_urls() : async [UrlStore.UrlView] {
    assertAuthenticated(caller);
    urlStore.getUrlsByOwner(caller);
  };

  public shared ({ caller }) func get_wallet_info() : async IcpLedger.WalletInfo {
    assertAuthenticated(caller);
    await IcpLedger.getWalletInfo(canisterPrincipal, caller);
  };

  public shared ({ caller }) func create_my_url(request : UrlStore.CreateRequest) : async Result.Result<UrlStore.UrlView, Text> {
    assertAuthenticated(caller);

    switch (urlStore.validateCreateRequest(request)) {
      case (#err(message)) {
        return #err(message);
      };
      case (#ok(())) {};
    };

    switch (await IcpLedger.chargeForUrl(canisterPrincipal, caller)) {
      case (#err(message)) {
        #err("Payment required before Tiny ICP can create your short URL. " # message);
      };
      case (#ok(())) {
        let metadata = await fetchUrlMetadata(request.originalUrl);
        switch (urlStore.create(request, caller, metadata)) {
          case (#ok(url)) #ok(urlStore.toView(url));
          case (#err(message)) #err(message);
        };
      };
    };
  };

  public shared ({ caller }) func delete_my_url(id : Nat) : async Result.Result<(), Text> {
    assertAuthenticated(caller);
    urlStore.delete(id, caller);
  };

  public shared ({ caller }) func withdraw_from_wallet(destinationAccountId : Text, amountE8s : Nat) : async Result.Result<(), Text> {
    assertAuthenticated(caller);
    await IcpLedger.withdrawFromWallet(canisterPrincipal, caller, destinationAccountId, amountE8s);
  };

  public shared query ({ caller }) func whoami() : async Principal {
    caller;
  };

  public query func transformPreviewMetadata(args : TransformArgs) : async HttpResponsePayload {
    {
      status = args.response.status;
      headers = [("content-type", "text/html; charset=utf-8")];
      body = args.response.body;
    };
  };

  func assertAuthenticated(caller : Principal) {
    if (Principal.isAnonymous(caller)) {
      Runtime.trap("Authentication required");
    };
  };

  func buildRouterConfig() : RouterMiddleware.Config {
    {
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
  };

  func buildApp(config : RouterMiddleware.Config) : Liminal.App {
    Liminal.App({
      middleware = [RouterMiddleware.new(config)];
      errorSerializer = Liminal.defaultJsonErrorSerializer;
      candidRepresentationNegotiator = Liminal.defaultCandidRepresentationNegotiator;
      logger = Liminal.buildDebugLogger(#info);
    });
  };

  func fetchUrlMetadata(originalUrl : Text) : async ?UrlStore.UrlMetadata {
    if (not Text.startsWith(originalUrl, #text("https://"))) {
      return null;
    };

    let request : HttpRequestArgs = {
      url = originalUrl;
      max_response_bytes = ?250_000;
      headers = [
        ("User-Agent", "TinyICPPreviewBot/1.0"),
        ("Accept", "text/html,application/xhtml+xml"),
      ];
      body = null;
      method = #get;
      transform = ?{
        function = transformPreviewMetadata;
        context = Blob.fromArray([]);
      };
    };

    let cycles = 230_000_000_000;
    ExperimentalCycles.add(cycles);

    try {
      let response = await ic.http_request(request);
      if (response.status < 200 or response.status >= 400) {
        return null;
      };

      let ?html = Text.decodeUtf8(response.body) else return null;
      let metadata = extractMetadata(html, originalUrl);

      if (
        metadata.title == null and metadata.description == null and metadata.imageUrl == null and metadata.canonicalUrl == null and metadata.siteName == null
      ) {
        null;
      } else {
        ?metadata;
      };
    } catch (error) {
      Runtime.print("Failed to fetch preview metadata for " # originalUrl # ": " # Error.message(error));
      null;
    };
  };

  func extractMetadata(html : Text, originalUrl : Text) : UrlStore.UrlMetadata {
    let ogTitle = extractMetaContent(html, "property", "og:title");
    let twitterTitle = extractMetaContent(html, "name", "twitter:title");
    let pageTitle = extractTitle(html);
    let ogDescription = extractMetaContent(html, "property", "og:description");
    let twitterDescription = extractMetaContent(html, "name", "twitter:description");
    let metaDescription = extractMetaContent(html, "name", "description");
    let ogImage = extractMetaContent(html, "property", "og:image");
    let twitterImage = extractMetaContent(html, "name", "twitter:image");
    let ogUrl = extractMetaContent(html, "property", "og:url");
    let canonical = extractLinkHref(html, "canonical");
    let siteName = extractMetaContent(html, "property", "og:site_name");

    {
      title = firstSome([ogTitle, twitterTitle, pageTitle]);
      description = firstSome([ogDescription, twitterDescription, metaDescription]);
      imageUrl = normalizePossibleUrl(firstSome([ogImage, twitterImage]), originalUrl);
      canonicalUrl = normalizePossibleUrl(firstSome([ogUrl, canonical]), originalUrl);
      siteName = siteName;
    };
  };

  func firstSome(values : [?Text]) : ?Text {
    for (value in values.vals()) {
      switch (value) {
        case (?text) {
          if (text != "") {
            return ?text;
          };
        };
        case null {};
      };
    };
    null;
  };

  func normalizePossibleUrl(value : ?Text, originalUrl : Text) : ?Text {
    switch (value) {
      case (?text) {
        if (Text.startsWith(text, #text("http://")) or Text.startsWith(text, #text("https://"))) {
          ?text;
        } else if (Text.startsWith(text, #text("//"))) {
          ?("https:" # text);
        } else if (Text.startsWith(text, #text("/"))) {
          ?(originFromUrl(originalUrl) # text);
        } else {
          null;
        };
      };
      case null null;
    };
  };

  func originFromUrl(url : Text) : Text {
    let parts = Text.split(url, #char('/'));
    var index = 0;
    var origin = "";
    label loop for (part in parts) {
      if (index == 0) {
        origin := part;
      } else if (index == 1) {
        origin := origin # "/" # part;
      } else if (index == 2) {
        origin := origin # "/" # part;
        break loop;
      };
      index += 1;
    };
    origin;
  };

  func extractMetaContent(html : Text, attributeName : Text, attributeValue : Text) : ?Text {
    let lowerHtml = Text.toLowercase(html);
    let marker = "<meta";
    var searchStart = 0;

    loop {
      let maybeIndex = findFrom(lowerHtml, marker, searchStart);
      switch (maybeIndex) {
        case null return null;
        case (?index) {
          let endIndex = switch (findFrom(lowerHtml, ">", index)) {
            case (?value) value;
            case null lowerHtml.size();
          };
          let length = endIndex - index + 1;
          let tag = sliceText(html, index, length);
          let lowerTag = Text.toLowercase(tag);
          let attrNeedle = attributeName # "=\"" # Text.toLowercase(attributeValue) # "\"";
          let attrNeedleSingle = attributeName # "='" # Text.toLowercase(attributeValue) # "'";
          if (Text.contains(lowerTag, #text(attrNeedle)) or Text.contains(lowerTag, #text(attrNeedleSingle))) {
            return firstSome([
              extractAttribute(tag, "content"),
              extractAttribute(tag, "value"),
            ]);
          };
          searchStart := endIndex + 1;
        };
      };
    };
  };

  func extractLinkHref(html : Text, relValue : Text) : ?Text {
    let lowerHtml = Text.toLowercase(html);
    let marker = "<link";
    var searchStart = 0;

    loop {
      let maybeIndex = findFrom(lowerHtml, marker, searchStart);
      switch (maybeIndex) {
        case null return null;
        case (?index) {
          let endIndex = switch (findFrom(lowerHtml, ">", index)) {
            case (?value) value;
            case null lowerHtml.size();
          };
          let length = endIndex - index + 1;
          let tag = sliceText(html, index, length);
          let lowerTag = Text.toLowercase(tag);
          let relNeedle = "rel=\"" # Text.toLowercase(relValue) # "\"";
          let relNeedleSingle = "rel='" # Text.toLowercase(relValue) # "'";
          if (Text.contains(lowerTag, #text(relNeedle)) or Text.contains(lowerTag, #text(relNeedleSingle))) {
            return extractAttribute(tag, "href");
          };
          searchStart := endIndex + 1;
        };
      };
    };
  };

  func extractTitle(html : Text) : ?Text {
    let lowerHtml = Text.toLowercase(html);
    let ?start = findFrom(lowerHtml, "<title>", 0) else return null;
    let contentStart = start + 7;
    let ?end = findFrom(lowerHtml, "</title>", contentStart) else return null;
    let raw = sliceText(html, contentStart, end - contentStart);
    cleanExtractedText(raw);
  };

  func extractAttribute(tag : Text, attributeName : Text) : ?Text {
    let lowerTag = Text.toLowercase(tag);
    let doubleNeedle = attributeName # "=\"";
    switch (findFrom(lowerTag, doubleNeedle, 0)) {
      case (?start) {
        let valueStart = start + doubleNeedle.size();
        let ?end = findFrom(tag, "\"", valueStart) else return null;
        return cleanExtractedText(sliceText(tag, valueStart, end - valueStart));
      };
      case null {};
    };

    let singleNeedle = attributeName # "='";
    switch (findFrom(lowerTag, singleNeedle, 0)) {
      case (?start) {
        let valueStart = start + singleNeedle.size();
        let ?end = findFrom(tag, "'", valueStart) else return null;
        return cleanExtractedText(sliceText(tag, valueStart, end - valueStart));
      };
      case null null;
    };
  };

  func cleanExtractedText(value : Text) : ?Text {
    let trimmed = trimWhitespace(value);
    if (trimmed == "") {
      null;
    } else {
      ?decodeHtmlEntities(trimmed);
    };
  };

  func trimWhitespace(value : Text) : Text {
    let chars = value.chars() |> Iter.toArray(_);
    if (chars.size() == 0) {
      return value;
    };

    var start : Nat = 0;
    var finished = false;
    while (start < chars.size() and not finished) {
      if (isWhitespace(chars[start])) {
        start += 1;
      } else {
        finished := true;
      };
    };

    if (start == chars.size()) {
      return "";
    };

    var end = chars.size();
    finished := false;
    while (end > start and not finished) {
      if (isWhitespace(chars[end - 1])) {
        end -= 1;
      } else {
        finished := true;
      };
    };

    var result = "";
    var index = start;
    while (index < end) {
      result := result # Text.fromChar(chars[index]);
      index += 1;
    };
    result;
  };

  func isWhitespace(char : Char) : Bool {
    char == ' ' or char == '\\n' or char == '\\r' or char == '\\t';
  };

  func decodeHtmlEntities(value : Text) : Text {
    value
    |> Text.replace(_, #text("&amp;"), "&")
    |> Text.replace(_, #text("&quot;"), "\"")
    |> Text.replace(_, #text("&#39;"), "'")
    |> Text.replace(_, #text("&apos;"), "'")
    |> Text.replace(_, #text("&lt;"), "<")
    |> Text.replace(_, #text("&gt;"), ">");
  };

  func sliceText(value : Text, start : Nat, length : Nat) : Text {
    let chars = value.chars();
    var index : Nat = 0;
    var output = "";
    for (char in chars) {
      if (index >= start and index < start + length) {
        output := output # Text.fromChar(char);
      };
      index += 1;
    };
    output;
  };

  func findFrom(haystack : Text, needle : Text, start : Nat) : ?Nat {
    if (needle == "") {
      return ?start;
    };

    let haystackChars = Blob.toArray(Text.encodeUtf8(haystack));
    let needleChars = Blob.toArray(Text.encodeUtf8(needle));
    if (needleChars.size() > haystackChars.size() or start >= haystackChars.size()) {
      return null;
    };

    let lastStart = haystackChars.size() - needleChars.size();
    var index = start;
    while (index <= lastStart) {
      var matched = true;
      var offset = 0;
      while (offset < needleChars.size()) {
        if (haystackChars[index + offset] != needleChars[offset]) {
          matched := false;
          offset := needleChars.size();
        } else {
          offset += 1;
        };
      };
      if (matched) {
        return ?index;
      };
      index += 1;
    };
    null;
  };

  transient var routerConfig : RouterMiddleware.Config = buildRouterConfig();

  transient var app : Liminal.App = buildApp(routerConfig);

  public query func http_request(request : Liminal.RawQueryHttpRequest) : async Liminal.RawQueryHttpResponse {
    app.http_request(request);
  };

  public func http_request_update(request : Liminal.RawUpdateHttpRequest) : async Liminal.RawUpdateHttpResponse {
    await* app.http_request_update(request);
  };
};
