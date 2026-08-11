// Vendored from eslint-plugin-header v3.1.1 (MIT).
"use strict";

module.exports = function parse(headerText) {
    var lines = headerText.split(/\r?\n/);
    var commentType = "line";
    if (lines[0].substr(0, 2) === "/*") {
        commentType = "block";
        // Trim open comment
        lines[0] = lines[0].slice(2);
        // Trim close comment
        lines[lines.length - 1] = lines[lines.length - 1].slice(0, -2);
    } else {
        // Trim comment
        lines = lines.map(function(line) {
            return line.slice(2);
        });
    }

    // Trim whitespace
    lines = lines.map(function(line) {
        return line.trim();
    });

    var eol = "\n";
    if (lines.every(function(line) {
        return line.startsWith("/") && line.endsWith("/");
    })) {
        // Could be a regex, convert to RegExp objects
        lines = lines.map(function(line) {
            return {
                pattern: line.slice(1, -1)
            };
        });
        if (/\*\/$/.test(headerText)) {
            commentType = "line";
            // Fix the last block comment line
            lines[lines.length - 1].pattern = lines[lines.length - 1].pattern.slice(0, -2);
            // Add new line to single-line patterns so they match at the end
            // of the header
            var lastLine = lines[lines.length - 1].pattern;
            lines[lines.length - 1].pattern = lastLine + "(?:\r?\n)*$";
        } else {
            commentType = "block";
            // Fix the last line comment pattern so it matches the close comment
            lines[lines.length - 1].pattern = lines[lines.length - 1].pattern + "/";
        }
        eol = "\\r?\\n";
    }

    return [commentType, lines, eol];
};