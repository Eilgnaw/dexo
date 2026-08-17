// Discourse currently ships class static initialization blocks. WebKit before
// iOS 16.4 cannot parse that syntax, so runtime polyfills never get a chance to
// run. ES Module Shims calls the source hook below before it creates the module
// blob, which lets us lower the syntax while keeping the real page, origin,
// cookies, CSP nonce, redirects, and challenge scripts untouched.

(function installModuleSyntaxCompatibility(global) {
  var identifierStartPattern = /[A-Za-z_$]/;
  var identifierPartPattern = /[A-Za-z0-9_$]/;
  var regexPrefixKeywords = {
    await: true,
    case: true,
    delete: true,
    do: true,
    else: true,
    in: true,
    instanceof: true,
    new: true,
    of: true,
    return: true,
    throw: true,
    typeof: true,
    void: true,
    yield: true,
  };
  var controlParenthesisKeywords = {
    catch: true,
    for: true,
    if: true,
    switch: true,
    while: true,
    with: true,
  };

  function isWhitespace(character) {
    return character === " " ||
      character === "\t" ||
      character === "\n" ||
      character === "\r" ||
      character === "\f" ||
      character === "\v" ||
      character === "\u00a0" ||
      character === "\u2028" ||
      character === "\u2029";
  }

  function skipQuotedString(source, index, quote) {
    index += 1;
    while (index < source.length) {
      var character = source[index];
      if (character === "\\") {
        index += 2;
      } else if (character === quote) {
        return index + 1;
      } else {
        index += 1;
      }
    }
    return index;
  }

  function skipLineComment(source, index) {
    index += 2;
    while (index < source.length && source[index] !== "\n" && source[index] !== "\r") {
      index += 1;
    }
    return index;
  }

  function skipBlockComment(source, index) {
    var end = source.indexOf("*/", index + 2);
    return end === -1 ? source.length : end + 2;
  }

  function skipTrivia(source, index) {
    while (index < source.length) {
      if (isWhitespace(source[index])) {
        index += 1;
      } else if (source[index] === "/" && source[index + 1] === "/") {
        index = skipLineComment(source, index);
      } else if (source[index] === "/" && source[index + 1] === "*") {
        index = skipBlockComment(source, index);
      } else {
        break;
      }
    }
    return index;
  }

  function skipRegularExpression(source, index) {
    var inCharacterClass = false;
    index += 1;
    while (index < source.length) {
      var character = source[index];
      if (character === "\\") {
        index += 2;
        continue;
      }
      if (character === "[" && !inCharacterClass) {
        inCharacterClass = true;
      } else if (character === "]" && inCharacterClass) {
        inCharacterClass = false;
      } else if (character === "/" && !inCharacterClass) {
        index += 1;
        while (index < source.length && identifierPartPattern.test(source[index])) {
          index += 1;
        }
        return index;
      } else if (character === "\n" || character === "\r") {
        return index;
      }
      index += 1;
    }
    return index;
  }

  function transformModuleSource(source) {
    if (typeof source !== "string" || source.indexOf("static") === -1) {
      return source;
    }

    var edits = [];
    var nextStaticBlockID = 0;
    var staticBlockByOpeningBrace = Object.create(null);
    var privateNamePrefix = "__dexo_static_block_";
    while (source.indexOf("#" + privateNamePrefix) !== -1) {
      privateNamePrefix = "_" + privateNamePrefix;
    }

    function scanTemplate(index) {
      index += 1;
      while (index < source.length) {
        var character = source[index];
        if (character === "\\") {
          index += 2;
        } else if (character === "`") {
          return index + 1;
        } else if (character === "$" && source[index + 1] === "{") {
          index = scanCode(index + 2, true);
        } else {
          index += 1;
        }
      }
      return index;
    }

    function scanCode(index, stopsAtClosingBrace) {
      var braces = [];
      var parentheses = [];
      var canStartRegex = true;
      var lastIdentifier = "";

      while (index < source.length) {
        var character = source[index];

        if (isWhitespace(character)) {
          index += 1;
          continue;
        }
        if (character === "/" && source[index + 1] === "/") {
          index = skipLineComment(source, index);
          continue;
        }
        if (character === "/" && source[index + 1] === "*") {
          index = skipBlockComment(source, index);
          continue;
        }
        if (character === "'" || character === '"') {
          index = skipQuotedString(source, index, character);
          canStartRegex = false;
          lastIdentifier = "";
          continue;
        }
        if (character === "`") {
          index = scanTemplate(index);
          canStartRegex = false;
          lastIdentifier = "";
          continue;
        }
        if (character === "/" && canStartRegex) {
          index = skipRegularExpression(source, index);
          canStartRegex = false;
          lastIdentifier = "";
          continue;
        }
        if (identifierStartPattern.test(character)) {
          var identifierStart = index;
          index += 1;
          while (index < source.length && identifierPartPattern.test(source[index])) {
            index += 1;
          }
          var identifier = source.slice(identifierStart, index);
          if (identifier === "static") {
            var openingBrace = skipTrivia(source, index);
            if (source[openingBrace] === "{") {
              nextStaticBlockID += 1;
              staticBlockByOpeningBrace[openingBrace] = nextStaticBlockID;
              edits.push({
                start: identifierStart,
                end: index,
                text: "static #" + privateNamePrefix + nextStaticBlockID + " = (() =>",
              });
            }
          }
          canStartRegex = !!regexPrefixKeywords[identifier];
          lastIdentifier = identifier;
          continue;
        }
        if ((character >= "0" && character <= "9") ||
            (character === "." && source[index + 1] >= "0" && source[index + 1] <= "9")) {
          index += 1;
          while (index < source.length && /[A-Za-z0-9_.]/.test(source[index])) {
            index += 1;
          }
          canStartRegex = false;
          lastIdentifier = "";
          continue;
        }

        if (character === "{") {
          braces.push(staticBlockByOpeningBrace[index] || 0);
          index += 1;
          canStartRegex = true;
          lastIdentifier = "";
          continue;
        }
        if (character === "}") {
          if (braces.length === 0 && stopsAtClosingBrace) {
            return index + 1;
          }
          var closingStaticBlockID = braces.pop() || 0;
          index += 1;
          if (closingStaticBlockID > 0) {
            edits.push({ start: index, end: index, text: ")();" });
          }
          canStartRegex = false;
          lastIdentifier = "";
          continue;
        }
        if (character === "(") {
          parentheses.push(!!controlParenthesisKeywords[lastIdentifier]);
          index += 1;
          canStartRegex = true;
          lastIdentifier = "";
          continue;
        }
        if (character === ")") {
          var closesControlParenthesis = parentheses.pop() || false;
          index += 1;
          canStartRegex = closesControlParenthesis;
          lastIdentifier = "";
          continue;
        }
        if (character === "[") {
          index += 1;
          canStartRegex = true;
          lastIdentifier = "";
          continue;
        }
        if (character === "]") {
          index += 1;
          canStartRegex = false;
          lastIdentifier = "";
          continue;
        }

        var pair = source.slice(index, index + 2);
        if (pair === "++" || pair === "--") {
          index += 2;
          canStartRegex = false;
        } else if (character === ".") {
          index += pair === "?." ? 2 : 1;
          canStartRegex = false;
        } else {
          index += 1;
          canStartRegex = true;
        }
        lastIdentifier = "";
      }
      return index;
    }

    scanCode(0, false);
    if (nextStaticBlockID === 0) return source;

    edits.sort(function (left, right) {
      return left.start === right.start ? left.end - right.end : left.start - right.start;
    });
    var output = "";
    var cursor = 0;
    for (var index = 0; index < edits.length; index += 1) {
      var edit = edits[index];
      output += source.slice(cursor, edit.start) + edit.text;
      cursor = edit.end;
    }
    return output + source.slice(cursor);
  }

  global.__dexoTransformModuleSource = transformModuleSource;
  global.__dexoESModuleSourceHook = async function (url, fetchOptions, parentURL, defaultSourceHook) {
    var loaded = await defaultSourceHook(url, fetchOptions, parentURL);
    if (loaded && loaded.type === "js" && typeof loaded.source === "string") {
      loaded.source = transformModuleSource(loaded.source);
    }
    return loaded;
  };
})(typeof window !== "undefined" ? window : globalThis);
