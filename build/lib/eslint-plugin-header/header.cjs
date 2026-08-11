// Vendored fork of eslint-plugin-header v3.1.1 (https://github.com/Stuk/eslint-plugin-header)
// Upstream is unmaintained (last publish 2022) and uses `context.getSourceCode()`,
// which ESLint 10 removed. This copy migrates those calls to `context.sourceCode`
// so the header rule keeps working on the latest ESLint. License: MIT.
'use strict';

const commentParser = require('./comment-parser.cjs');
const os = require('os');

function isPattern(object) {
	return typeof object === 'object' && Object.prototype.hasOwnProperty.call(object, 'pattern');
}

function match(actual, expected) {
	if (expected.test) {
		return expected.test(actual);
	} else {
		return expected === actual;
	}
}

function excludeShebangs(comments) {
	return comments.filter(function (comment) {
		return comment.type !== 'Shebang';
	});
}

// Returns either the first block comment or the first set of line comments that
// are ONLY separated by a single newline. Note that this does not actually
// check if they are at the start of the file since that is already checked by
// hasHeader().
function getLeadingComments(context, node) {
	const all = excludeShebangs(context.sourceCode.getAllComments(node.body.length ? node.body[0] : node));
	if (all[0].type.toLowerCase() === 'block') {
		return [all[0]];
	}
	for (let i = 1; i < all.length; ++i) {
		const txt = context.sourceCode.getText().slice(all[i - 1].range[1], all[i].range[0]);
		if (!txt.match(/^(\r\n|\r|\n)$/)) {
			break;
		}
	}
	return all.slice(0, i);
}

function genCommentBody(commentType, textArray, eol, numNewlines) {
	const eols = eol.repeat(numNewlines);
	if (commentType === 'block') {
		return '/*' + textArray.join(eol) + '*/' + eols;
	} else {
		return '//' + textArray.join(eol + '//') + eols;
	}
}

function genCommentsRange(context, comments, eol) {
	const start = comments[0].range[0];
	let end = comments.slice(-1)[0].range[1];
	if (context.sourceCode.text[end] === eol) {
		end += eol.length;
	}
	return [start, end];
}

function genPrependFixer(commentType, node, headerLines, eol, numNewlines) {
	return function (fixer) {
		return fixer.insertTextBefore(
			node,
			genCommentBody(commentType, headerLines, eol, numNewlines)
		);
	};
}

function genReplaceFixer(commentType, context, leadingComments, headerLines, eol, numNewlines) {
	return function (fixer) {
		return fixer.replaceTextRange(
			genCommentsRange(context, leadingComments, eol),
			genCommentBody(commentType, headerLines, eol, numNewlines)
		);
	};
}

function findSettings(options) {
	const lastOption = options.length > 0 ? options[options.length - 1] : null;
	if (typeof lastOption === 'object' && !Array.isArray(lastOption) && lastOption !== null
		&& !Object.prototype.hasOwnProperty.call(lastOption, 'pattern')) {
		return lastOption;
	}
	return null;
}

function getEOL(options) {
	const settings = findSettings(options);
	if (settings && settings.lineEndings === 'unix') {
		return '\n';
	}
	if (settings && settings.lineEndings === 'windows') {
		return '\r\n';
	}
	return os.EOL;
}

function hasHeader(src) {
	if (src.substr(0, 2) === '#!') {
		const m = src.match(/(\r\n|\r|\n)/);
		if (m) {
			src = src.slice(m.index + m[0].length);
		}
	}
	return src.substr(0, 2) === '/*' || src.substr(0, 2) === '//';
}

function matchesLineEndings(src, num) {
	for (let j = 0; j < num; ++j) {
		const m = src.match(/^(\r\n|\r|\n)/);
		if (m) {
			src = src.slice(m.index + m[0].length);
		} else {
			return false;
		}
	}
	return true;
}

module.exports = {
	rules: {
		header: {
			meta: {
				type: 'layout',
				fixable: 'whitespace',
				schema: false
			},
			create: function (context) {
				let options = context.options;
				let numNewlines = options.length > 2 ? options[2] : 1;
				const eol = getEOL(options);

				// If just one option then read comment from file
				if (options.length === 1 || (options.length === 2 && findSettings(options))) {
					const text = require('fs').readFileSync(context.options[0], 'utf8');
					options = commentParser(text);
				}

				const commentType = options[0].toLowerCase();
				let headerLines;
				let fixLines = [];
				// If any of the lines are regular expressions, then we can't
				// automatically fix them. We set this to true below once we
				// ensure none of the lines are of type RegExp
				let canFix = false;
				if (Array.isArray(options[1])) {
					canFix = true;
					headerLines = options[1].map(function (line) {
						const isRegex = isPattern(line);
						// Can only fix regex option if a template is also provided
						if (isRegex && !line.template) {
							canFix = false;
						}
						fixLines.push(line.template || line);
						return isRegex ? new RegExp(line.pattern) : line;
					});
				} else if (isPattern(options[1])) {
					const line = options[1];
					headerLines = [new RegExp(line.pattern)];
					fixLines.push(line.template || line);
					// Same as above for regex and template
					canFix = !!line.template;
				} else {
					canFix = true;
					headerLines = options[1].split(/\r?\n/);
					fixLines = headerLines;
				}

				return {
					Program: function (node) {
						if (!hasHeader(context.sourceCode.getText())) {
							context.report({
								loc: node.loc,
								message: 'missing header',
								fix: genPrependFixer(commentType, node, fixLines, eol, numNewlines)
							});
						} else {
							const leadingComments = getLeadingComments(context, node);

							if (!leadingComments.length) {
								context.report({
									loc: node.loc,
									message: 'missing header',
									fix: canFix ? genPrependFixer(commentType, node, fixLines, eol, numNewlines) : null
								});
							} else if (leadingComments[0].type.toLowerCase() !== commentType) {
								context.report({
									loc: node.loc,
									message: 'header should be a {{commentType}} comment',
									data: {
										commentType: commentType
									},
									fix: canFix ? genReplaceFixer(commentType, context, leadingComments, fixLines, eol, numNewlines) : null
								});
							} else {
								if (commentType === 'line') {
									if (leadingComments.length < headerLines.length) {
										context.report({
											loc: node.loc,
											message: 'incorrect header',
											fix: canFix ? genReplaceFixer(commentType, context, leadingComments, fixLines, eol, numNewlines) : null
										});
										return;
									}
									for (let i = 0; i < headerLines.length; i++) {
										if (!match(leadingComments[i].value, headerLines[i])) {
											context.report({
												loc: node.loc,
												message: 'incorrect header',
												fix: canFix ? genReplaceFixer(commentType, context, leadingComments, fixLines, eol, numNewlines) : null
											});
											return;
										}
									}

									const postLineHeader = context.sourceCode.text.substr(leadingComments[headerLines.length - 1].range[1], numNewlines * 2);
									if (!matchesLineEndings(postLineHeader, numNewlines)) {
										context.report({
											loc: node.loc,
											message: 'no newline after header',
											fix: canFix ? genReplaceFixer(commentType, context, leadingComments, fixLines, eol, numNewlines) : null
										});
									}

								} else {
									// if block comment pattern has more than 1 line, we also split the comment
									let leadingLines = [leadingComments[0].value];
									if (headerLines.length > 1) {
										leadingLines = leadingComments[0].value.split(/\r?\n/);
									}

									let hasError = false;
									if (leadingLines.length > headerLines.length) {
										hasError = true;
									}
									for (let i = 0; !hasError && i < headerLines.length; i++) {
										if (!match(leadingLines[i], headerLines[i])) {
											hasError = true;
										}
									}

									if (hasError) {
										if (canFix && headerLines.length > 1) {
											fixLines = [fixLines.join(eol)];
										}
										context.report({
											loc: node.loc,
											message: 'incorrect header',
											fix: canFix ? genReplaceFixer(commentType, context, leadingComments, fixLines, eol, numNewlines) : null
										});
									} else {
										const postBlockHeader = context.sourceCode.text.substr(leadingComments[0].range[1], numNewlines * 2);
										if (!matchesLineEndings(postBlockHeader, numNewlines)) {
											context.report({
												loc: node.loc,
												message: 'no newline after header',
												fix: canFix ? genReplaceFixer(commentType, context, leadingComments, fixLines, eol, numNewlines) : null
											});
										}
									}
								}
							}
						}
					}
				};
			}
		}
	}
};
