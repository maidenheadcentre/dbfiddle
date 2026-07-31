// Vendored from markdown-it-br 1.0.0 (MIT), unmaintained since 2017.
// Copyright (c) 2014-2015 Vitaly Puzrin, Alex Kocharin.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Turns a literal <br> in the markdown source into a real tag. escapeMarkdownCell
// emits one per newline inside a result cell, and this is what lets those render
// while html:false keeps every other tag in untrusted output escaped.

export default function br_plugin(md) {

  function tokenize(state, silent) {
    const max = state.posMax;
    const start = state.pos;
    const marker = state.src.charCodeAt(start);
    if (start + 4 > max) { return false; } // <br> length
    if (silent) { return false; } // don't run any pairs in validation mode

    if (marker === 60 /* < */ &&
      (state.src.charCodeAt(start + 1) === 66 || state.src.charCodeAt(start + 1) === 98) /* B or b */ &&
      (state.src.charCodeAt(start + 2) === 82 || state.src.charCodeAt(start + 2) === 114) /* R or r */ &&
      state.src.charCodeAt(start + 3) === 62 /* > */
      ) {
      state.scanDelims(state.pos, true);
      const token = state.push('text', '', 0);
      token.content = '<br>';
      state.delimiters.push({
        marker: token.content,
        jump:   0,
        token:  state.tokens.length - 1,
        level:  state.level,
        end:    -1,
        open:   true,
        close:  true
      });
    } else {
      return false;
    }

    state.pos += 4;

    return true;
  }

  // Walk through delimiter list and replace text tokens with tags
  function postProcess(state) {
    const delimiters = state.delimiters;
    const max = state.delimiters.length;

    for (let i = 0; i < max; i++) {
      const delim = delimiters[i];

      if (delim.marker === '<br>') {
        const token = state.tokens[delim.token];
        token.type    = 'br_openclose';
        token.tag     = 'br';
        token.nesting = 1;
        token.markup  = '<br>';
        token.content = '';
      }
    }
  }

  md.inline.ruler.before('emphasis', 'br', tokenize);
  md.inline.ruler2.before('emphasis', 'br', postProcess);

}
