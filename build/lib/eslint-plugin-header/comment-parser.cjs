/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

/*
 * Vendored from eslint-plugin-header v3.1.1.
 * Copyright (c) Stuart Knightley, 2020
 * https://github.com/Stuk/eslint-plugin-header
 *
 * Distributed under the MIT License, as published by the upstream project.
 * The upstream MIT License text is reproduced below; the Microsoft header
 * above governs the fork-specific modifications made in this repository.
 *
 * MIT License
 *
 * Copyright (c) Stuart Knightley
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

"use strict";

module.exports = function parse(headerText) {
    let lines = headerText.split(/\r?\n/);
    let commentType = "line";
    if (lines[0].substr(0, 2) === "/*") {
        commentType = "block";
        // Trim open comment
        lines[0] = lines[0].slice(2);
        // Trim close comment
        lines[lines.length - 1] = lines[lines.length - 1].slice(0, -2);
    } else {
        // Trim comment
        lines = lines.map(function (line) {
            return line.slice(2);
        });
    }

    // Trim whitespace
    lines = lines.map(function (line) {
        return line.trim();
    });

    let eol = "\n";
    if (lines.every(function (line) {
        return line.startsWith("/") && line.endsWith("/");
    })) {
        // Could be a regex, convert to RegExp objects
        lines = lines.map(function (line) {
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
            const lastLine = lines[lines.length - 1].pattern;
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
