import { EditorView } from "codemirror";
import { EditorState, Compartment } from '@codemirror/state'
import { keymap, highlightSpecialChars, drawSelection, highlightActiveLine, dropCursor, rectangularSelection, crosshairCursor, lineNumbers, highlightActiveLineGutter} from '@codemirror/view'
import { standardKeymap, history, historyKeymap, indentLess, indentMore, toggleComment } from "@codemirror/commands"
import { defaultHighlightStyle, syntaxHighlighting, bracketMatching, foldGutter, foldKeymap } from '@codemirror/language'
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search';
import { lintKeymap } from '@codemirror/lint'
import { javascript } from '@codemirror/lang-javascript';
import { sql, StandardSQL, PostgreSQL, MySQL, MariaSQL, MSSQL, SQLite, PLSQL } from '@codemirror/lang-sql';

const editorFromTextArea = (textarea,engine) => {
  const lang = (engine === 'nodejs') ? javascript() : sql({ dialect: (engine === 'postgres') ? PostgreSQL
                                                                   : (engine === 'mysql') ? MySQL
                                                                   : (engine === 'mariadb') ? MariaSQL
                                                                   : (engine === 'sqlserver') ? MSSQL
                                                                   : (engine === 'sqlite') ? SQLite
                                                                   : (engine === 'oracle') ? PLSQL
                                                                   : StandardSQL });
  let editable = new Compartment;
  let view = new EditorView({ doc: textarea.value, extensions: [
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightSpecialChars(),
    history(),
    foldGutter(),
    drawSelection(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    syntaxHighlighting(defaultHighlightStyle, {fallback: true}),
    bracketMatching(),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    lang,
    editable.of(EditorState.readOnly.of(false)),
    keymap.of([
      ...standardKeymap,
      ...searchKeymap,
      ...historyKeymap,
      ...foldKeymap,
      ...lintKeymap,
      { key: 'Mod-Enter', run: function(){ document.getElementById('run').click(); } },
      { key: "Mod-[", run: indentLess },
      { key: "Mod-]", run: indentMore },
      { key: "Mod-/", run: toggleComment },
      ]),
    EditorView.updateListener.of(update => {
      if (update.docChanged){
        document.getElementById('markdown').disabled = true;
        const line = view.dom.closest('.line');
        if(!line.nextElementSibling){
          line.querySelector('.plus:last-child').click();
          view.focus();
        }
      };
    }),
  ] });
  view.setEditable = b => view.dispatch({ effects: editable.reconfigure(EditorState.readOnly.of(!b)) });
  textarea.parentNode.insertBefore(view.dom, textarea);
  textarea.remove();
  return view;
};

export { editorFromTextArea };
