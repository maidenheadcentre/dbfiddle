import { EditorView } from "codemirror";
import { EditorState, Compartment } from '@codemirror/state'
import { keymap, highlightSpecialChars, drawSelection, highlightActiveLine, dropCursor, rectangularSelection, crosshairCursor, lineNumbers, highlightActiveLineGutter, showPanel} from '@codemirror/view'
import { standardKeymap, history, historyKeymap, indentLess, indentMore, toggleComment } from "@codemirror/commands"
import { defaultHighlightStyle, syntaxHighlighting, bracketMatching, foldGutter, foldKeymap, StreamLanguage } from '@codemirror/language'
import { searchKeymap, highlightSelectionMatches } from '@codemirror/search';
import { lintKeymap } from '@codemirror/lint'
import { javascript } from '@codemirror/lang-javascript';
import { python } from '@codemirror/lang-python';
import { cpp } from '@codemirror/lang-cpp';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { sql, StandardSQL, PostgreSQL, MySQL, MariaSQL, MSSQL, SQLite, PLSQL } from '@codemirror/lang-sql';

const languageExtension = (engine,lang) => [
    (lang === 'node') ? javascript()
  : (lang === 'mongosh') ? javascript()
  : (lang === 'python') ? python()
  : (lang === 'c') ? cpp()
  : (lang === 'bash') ? StreamLanguage.define(shell)
  : sql({ dialect: (engine === 'postgres') ? PostgreSQL
                 : (engine === 'mysql') ? MySQL
                 : (engine === 'mariadb') ? MariaSQL
                 : (engine === 'sqlserver') ? MSSQL
                 : (engine === 'sqlite') ? SQLite
                 : (engine === 'oracle') ? PLSQL
                 : StandardSQL }),
  showPanel.of((!lang || lang === 'sql') ? null : () => {
    const dom = document.createElement('div');
    dom.className = 'cm-lang';
    dom.textContent = lang;
    return { dom, top: true };
  }),
];

const editorFromTextArea = (textarea,engine,lang) => {
  let language = new Compartment;
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
    language.of(languageExtension(engine,lang)),
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
  view.setLanguage = (engine,lang) => view.dispatch({ effects: language.reconfigure(languageExtension(engine,lang)) });
  textarea.parentNode.insertBefore(view.dom, textarea);
  textarea.remove();
  return view;
};

export { editorFromTextArea };
