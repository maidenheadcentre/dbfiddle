(function() {

  const editors = [];
  const runButton = document.getElementById('run');
  const hashVals = window.location.hash ? window.location.hash.substring(1).split('.') : null;

  const engineCode = () => document.getElementById('engine').value;
  // 'sql' is the wire spelling of "no data-lang", never a value the runners see
  const speaks = () => (document.querySelector('.version:not(.hidden)').selectedOptions[0]?.dataset.languages ?? 'sql').split(',');
  const languageName = code => JSON.parse(document.querySelector('main').dataset.languages)[code] ?? code;
  const gate = () => document.querySelector('main').classList.toggle('multilingual', speaks().length > 1);

  const MAX_SOURCE = 500000;
  const MAX_VALUES = 100000;

  // the output is a program's stdout, so this is the gate, not a formality
  const validateOption = source => {
    if (source.length > MAX_SOURCE) throw new Error(`output is ${source.length.toLocaleString()} characters; the renderer accepts up to ${MAX_SOURCE.toLocaleString()}`);
    const option = JSON.parse(source);
    if (option === null || typeof option !== 'object' || Array.isArray(option)) throw new Error(`expected an object, got ${option === null ? 'null' : Array.isArray(option) ? 'an array' : typeof option}`);
    let values = 0;
    const walk = (node, path) => {
      if (node && typeof node === 'object') {
        for (const [k, v] of Object.entries(node)) walk(v, `${path}.${k}`);
      } else {
        values++;
        if (typeof node === 'string' && /^(image:\/\/|https?:\/\/|\/\/)/i.test(node)) throw new Error(`remote reference at ${path}: ${node}`);
      }
    };
    walk(option, 'option');
    if (values > MAX_VALUES) throw new Error(`the option has ${values.toLocaleString()} values; the renderer accepts up to ${MAX_VALUES.toLocaleString()}`);
    return option;
  };

  let diagrams = 0;
  // keys must match RENDERERS in site/fiddle/index.mjs, which allowlists the query string
  const RENDERERS = {
    echarts: {
      global: 'echarts',
      parse: validateOption,
      draw: (div, option) => {
        // the two places echarts writes option strings as html; the tooltip only switches before the first setOption
        for (const tooltip of [option.tooltip ?? []].flat()) tooltip.renderMode = 'richText';
        for (const toolbox of [option.toolbox ?? []].flat()) delete toolbox.feature?.dataView?.lang;
        const chart = echarts.init(div, null, { renderer: 'svg' });
        chart.setOption(option);
        // echarts sizes itself once at init and never again on its own
        new ResizeObserver(() => chart.resize()).observe(div);
      },
    },
    mermaid: {
      global: 'mermaid',
      parse: text => text,
      draw: async (div, text) => {
        mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true });
        // only the svg: bindFunctions would hang flowchart tooltips off the body
        const { svg } = await mermaid.render(`mermaid-${++diagrams}`, text);
        div.innerHTML = svg;
      },
    },
  };

  const loading = {};
  const load = (src, global) => loading[src] ??= new Promise((ok, fail) => {
    if (window[global]) return ok();
    const s = document.createElement('script');
    s.src = src; s.onload = ok; s.onerror = () => fail(new Error(`could not load ${src}`));
    document.head.append(s);
  });

  // status and error fences are a blockquote's pre; only stdout is the output's own
  const stdout = output => output.querySelector(':scope > pre');
  const single = output => {
    const tables = output.querySelectorAll(':scope > table');
    return tables.length === 1 && tables[0].querySelectorAll('th').length === 1 && tables[0].querySelectorAll('td').length === 1 ? tables[0] : null;
  };
  // from the markdown, not the td: markdown-it has already unescaped \" and \\ there
  const cell = markdown => markdown.match(/^\|[:-]+\|\n\| (.*) \|$/m)[1].replace(/\\([[*/|`_<&])|<br>|&numsp;/g, (m, c) => c ?? (m === '<br>' ? '\n' : ' '));

  const paint = async line => {
    const output = line.querySelector('.output');
    output.querySelector('.figure')?.remove();
    for (const shown of output.querySelectorAll('.rendered')) shown.classList.remove('rendered');
    const name = line.dataset.render;
    const token = line.painting = {};
    if (!name || output.children.length === 0) return;
    const code = 'lang' in line.dataset;
    const source = code ? stdout(output) : single(output);
    const figure = Object.assign(document.createElement('div'), { className: 'figure' });
    figure.append(Object.assign(document.createElement('div'), { className: 'renderer', textContent: name }));
    (source ?? output.firstElementChild).before(figure);
    const hide = () => { for (const html of code && source ? [source] : output.children) if (html !== figure) html.classList.add('rendered'); };
    const fail = message => {
      const raw = code && source ? source.textContent : output.dataset.markdown;
      figure.append(Object.assign(document.createElement('code'), { className: 'language-error', textContent: message }), Object.assign(document.createElement('pre'), { textContent: raw }));
      hide();
    };
    if (!source) return fail(`nothing to render: expected ${code ? 'a code block of printed output' : 'a table of one row and one column'}`);
    try {
      const renderer = RENDERERS[name];
      const parsed = renderer.parse(code ? source.textContent : cell(output.dataset.markdown));
      await load(document.querySelector('main').dataset[name], renderer.global);
      if (line.painting !== token) return;
      const chart = Object.assign(document.createElement('div'), { className: 'chart' });
      chart.dataset.render = name;
      figure.append(chart);
      hide();
      await renderer.draw(chart, parsed);
    } catch (e) {
      if (line.painting !== token) return;
      figure.querySelector('.chart')?.remove();
      fail(e.message);
    }
  };

  const renderParam = () => Array.from(document.querySelectorAll('.line')).map(l => l.dataset.render ?? '').join(',').replace(/,+$/, '');
  // commas are safe in a query string, and ?render=,,echarts is meant to be readable
  const search = params => params.toString() ? '?' + params.toString().replaceAll('%2C', ',') : '';
  const syncRender = () => {
    const params = new URLSearchParams(window.location.search);
    const value = renderParam();
    if (value) params.set('render', value); else params.delete('render');
    history.replaceState('', document.title, window.location.pathname + search(params));
  };

  const setLang = (line, editor, lang) => {
    if((line.dataset.lang ?? 'sql') !== lang) document.getElementById('markdown').disabled = true;
    if(lang === 'sql') delete line.dataset.lang; else line.dataset.lang = lang;
    editor.setLanguage(engineCode(), lang);
  };

  const scanGo = text => {
    const pieces = [];
    let piece = [], depth = 0, close = null, split = true;
    for (const line of text.split('\n')) {
      const go = !close && !depth && line.match(/^\s*go(?:\s+(\d+))?\s*(?:--.*)?$/i);
      if (go) {
        if (go[1]) split = false;
        pieces.push(piece.join('\n'));
        piece = [];
        continue;
      }
      piece.push(line);
      for (let i = 0; i < line.length; i++) {
        const c = line[i], two = line.slice(i, i + 2);
        if (depth) {
          if (two === '/*') { depth++; i++; } else if (two === '*/') { depth--; i++; }
        } else if (close) {
          if (c === close) { if (line[i + 1] === close) i++; else close = null; }
        } else if (two === '--') {
          break;
        } else if (two === '/*') {
          depth = 1; i++;
        } else if (c === "'" || c === '"') {
          close = c;
        } else if (c === '[') {
          close = ']';
        }
      }
    }
    if (close || depth) return null;
    pieces.push(piece.join('\n'));
    return { pieces: pieces.filter(p => p.trim()), split };
  };

  const PLSQL = /^(declare|begin|create\s+(or\s+replace\s+)?(and\s+(resolve|compile)\s+)?(noforce\s+)?((editionable|noneditionable)\s+)?(function|procedure|package|trigger|type|library|java)|with\s+(function|procedure))\b/i;
  const SQLPLUS = /^(@|set\s+(?!(transaction|role|constraints?)\b)\w|(col|column|pro|prompt|sho|show|desc|describe|spool|exec|execute|var|variable|def|define|undef|undefine|whenever|rem|remark|start|conn|connect|disc|disconnect|acc|accept|pause|tti|ttitle|bti|btitle|bre|break|comp|compute|cl|clear|ho|host|timing|print|r|run|l|list|sav|save|get|ed|edit|store|repheader|repfooter|startup|shutdown|recover|copy|help)\b)/i;

  const scanSemicolon = text => {
    const pieces = [];
    let start = 0, i = 0, close = null, depth = 0, line = false, split = true, plsql = null;
    const head = () => text.slice(start, i).replace(/^(\s|--[^\n]*|\/\*[\s\S]*?\*\/)*/, '');
    const end = (to, next = to) => { pieces.push(text.slice(start, to).trim()); start = next; plsql = null; };
    while (i < text.length) {
      const c = text[i], two = text.slice(i, i + 2);
      if (line) { if (c === '\n') line = false; i++; continue; }
      if (depth) { if (two === '*/') { depth = 0; i += 2; } else i++; continue; }
      if (close) {
        if (close.length === 2) { if (two === close) { close = null; i += 2; } else i++; continue; }
        if (c === close) { if (text[i + 1] === close) { i += 2; continue; } close = null; }
        i++; continue;
      }
      const atLineStart = i === 0 || text[i - 1] === '\n';
      if (atLineStart && /^[ \t]*\/[ \t]*(\n|$)/.test(text.slice(i))) {
        if (!head().trim()) split = false;
        const eol = text.indexOf('\n', i);
        end(i, eol < 0 ? text.length : eol);
        i = eol < 0 ? text.length : eol;
        continue;
      }
      if (plsql === null && /\S/.test(c) && two !== '--' && two !== '/*') {
        const rest = text.slice(i);
        plsql = PLSQL.test(rest);
        if (SQLPLUS.test(rest)) split = false;
      }
      if (two === '--') { line = true; i += 2; continue; }
      if (two === '/*') { depth = 1; i += 2; continue; }
      const q = text.slice(i).match(/^n?q'(.)/i);
      if (q && !/\w/.test(text[i - 1] ?? '')) {
        close = ({ '[': ']', '{': '}', '<': '>', '(': ')' }[q[1]] ?? q[1]) + "'";
        i += q[0].length; continue;
      }
      if (c === "'" || c === '"') { close = c; i++; continue; }
      if (c === ';' && plsql === false) {
        const comment = text.slice(i + 1).match(/^[ \t]*(--[^\n]*|\/\*[^\n]*?\*\/[ \t]*)?(?=\n|$)/);
        i += 1 + (comment?.[1] ? comment[0].length : 0);
        end(i);
        continue;
      }
      i++;
    }
    if (close || depth) return null;
    // a PL/SQL unit with no slash never runs in SQL*Plus
    const slash = !!plsql;
    if (head().trim() || !pieces.length) end(text.length);
    else pieces[pieces.length - 1] += text.slice(start).trimEnd();
    return { pieces: pieces.filter(p => p.trim()), split, slash };
  };

  const SCRIPTS = {
    sqlserver: { scan: scanGo, lang: 'sqlcmd', found: n => `${n} batches separated by GO` },
    oracle: { scan: scanSemicolon, lang: 'sqlplus', found: n => `${n} statements` },
  };

  const replaceWith = (line, statements) => {
    const plus = line.querySelector('.plus:first-child');
    const template = document.querySelector('template').content.querySelector('textarea');
    for (const statement of statements) {
      template.value = statement;
      plus.click();
      template.value = '';
    }
    line.querySelector('.remove').click();
  };

  const offer = (line, editor) => {
    const script = SCRIPTS[engineCode()];
    const assists = 'assistsSplit' in document.querySelector('.version:not(.hidden)').selectedOptions[0].dataset;
    const found = script && assists && !line.dataset.lang && script.scan(editor.state.doc.toString());
    if (!found || (found.split && found.pieces.length < 2)) return;
    const speaksIt = speaks().includes(script.lang);
    const split = found.split && found.pieces.length > 1;
    if (!split && !speaksIt) return;
    const bar = Object.assign(document.createElement('div'), { className: 'cm-offer' });
    const button = (text, act) => bar.append(Object.assign(document.createElement('button'), { textContent: text, onclick: () => { editor.setOffer(null); act?.(); } }));
    bar.append(split ? `${script.found(found.pieces.length)}: ` : 'run as ');
    if (split) button('split', () => replaceWith(line, found.pieces.map(p => p.replace(/^(\s*\n)+/, '').trimEnd())));
    if (split && speaksIt) bar.append(' or use ');
    if (speaksIt) button(languageName(script.lang), () => {
      if (found.slash) editor.dispatch({ changes: { from: editor.state.doc.length, insert: '\n/' } });
      setLang(line, editor, script.lang);
    });
    if (!split) bar.append('?');
    button('×');
    editor.setOffer(bar);
  };

  history.replaceState("", document.title, window.location.pathname + window.location.search);

  for (const textarea of document.querySelectorAll('textarea')) {
    editors.push(cm.editorFromTextArea(textarea, engineCode(), textarea.closest('.line').dataset.lang));
  }

  gate();

  if(hashVals){
    editors[+hashVals[0]].focus();
    editors[+hashVals[0]].dispatch({ selection: { anchor: +hashVals[1], head: +hashVals[1] } });
  };

  for (const table of document.querySelectorAll('.output>table')) {
    const th = table.querySelector('th');
    if(th.textContent === 'Microsoft SQL Server 2005 XML Showplan'){
      const div = document.createElement('div');
      table.after(div);
      QP.showPlan(div, table.querySelector('td').textContent, false);
    }
  }

  for (const line of document.querySelectorAll('.line[data-render]')) paint(line);

  document.getElementById('markdown').addEventListener('click', async e => {
    let markdown = '';

    for (const line of document.querySelectorAll('.line')){
      if(!line.classList.contains('hide')){
        markdown += line.querySelector('.input').dataset.markdown;
        markdown += line.querySelector('.output').dataset.markdown;
      }
    }

    markdown += `[fiddle](${window.location.href})\n`;
    let message = 'Markdown copied to clipboard.';
    if( (document.querySelectorAll('.line').length > 1) && (document.querySelectorAll('.line.hide').length === 0) ){
      message += '\n\nConsider using hidden batches for sites like Stack Overflow; hidden batches are not included in the markdown (but can be expanded after visiting the fiddle link).';
    };
    navigator.clipboard.writeText(markdown).then(() => alert(message));
  });

  document.getElementById('clear').addEventListener('click', e => {
    const lines = Array.from(document.querySelectorAll('.line'));
    lines[lines.length-1].querySelector('.plus:last-child').click();
    lines.forEach(line => line.querySelector('.remove').click());
  });

  runButton.addEventListener('click', async e => {

    if (runButton.dataset.replacement) {
      const versionSelect = document.querySelector('.version:not(.hidden)');
      versionSelect.value = runButton.dataset.replacement;
      versionSelect.dispatchEvent(new Event('change'));
    }

    const remove = [];
    editors.forEach((e,i) => { if(e.state.doc.toString().trim()==='') remove.push(document.querySelectorAll('.line')[i].querySelector('.icon.remove')) });
    if(remove.length === editors.length) return;
    remove.forEach(e => e.click());

    const batches = [];
    const langs = [];
    const lines = document.querySelectorAll('.line');
    const hide = parseInt(Array.from(lines).reduce((p,c,i) => p + (c.classList.contains('hide')?'1':'0'), '' ),2);
    let hash = '';

    for (const [index, editor] of editors.entries()){
      editor.setEditable(false);
      batches.push(editor.state.doc.toString());
      langs.push(lines[index]?.dataset.lang ?? '');
      if(editor.dom.classList.contains('cm-focused')) hash = `#${index}.${editor.state.selection.ranges[0].from}`;
    }
    const payload = langs.some(l => l) ? batches.map((b,i) => [b, langs[i]]) : batches;

    let query = '?engine=' + document.getElementById('engine').value + '&version=' + document.querySelector('.version:not(.hidden)').value;
    const sampleElement = document.querySelector('.sample:not(.hidden)');
    if( (sampleElement !== null) && (sampleElement.value !== '') ) query += '&sample=' + sampleElement.value;

    for (const b of document.querySelectorAll('#markdown, #clear')) b.disabled = true;
    runButton.disabled = true;
    runButton.classList.add('running');

    let aborted = false;
    let failure = 'The run did not complete. Please try again later.';

    try {

      const controller = new AbortController();

      document.getElementById('abort').addEventListener("click", () => {
        if (controller) {
          aborted = true;
          controller.abort();
        }
      });

      const response = await fetch('run' + query, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });

      if (response.status !== 200) {
        // only a dbfiddle-marked body is meant for a user; API Gateway's is not
        const why = await response.json().catch(() => null);
        if (why?.dbfiddle) failure = why.message;
        throw new Error(failure);
      }

      const params = new URLSearchParams();
      if(hide) params.append('hide',hide);
      const render = renderParam();
      if(render) params.append('render',render);

      window.location = (await response.text()) + search(params) + hash;

    } catch (e) {
      if(!aborted) alert(failure);
    } finally {
      for (const editor of editors) editor.setEditable(true);
      for (const b of document.querySelectorAll('#markdown, #clear')) b.disabled = false;
      runButton.disabled = false;
      runButton.classList.remove('running');
    }

  });

  document.querySelector('main').addEventListener('batchchange', event => setTimeout(() => {
    const editor = editors.find(e => e.dom === event.target);
    if (!editor) return;
    editor.setOffer(null);
    if (event.detail.paste) offer(event.target.closest('.line'), editor);
  }));

  document.querySelector('main').addEventListener("click", event => {
    const icon = event.target.closest('.icon');
    if(icon) {
      const line = icon.closest('.line');

      let index = 0
      {
        let sibling = line;
        while (sibling = sibling.previousElementSibling) index++;
      }

      if (icon.classList.contains("plus")) {
        const clone = document.querySelector('template').content.cloneNode(true);
        const editor = cm.editorFromTextArea(clone.querySelector('textarea'),engineCode());
        if(icon.nextElementSibling){
          line.before(clone);
          editors.splice(index,0,editor);
        } else {
          line.after(clone);
          editors.splice(index+1,0,editor);
        }
        editor.focus();
        return;
      }

      if (icon.classList.contains("show")) {
        let hidden = line;
        do {
          if(!hidden.classList.contains('hide')) break;
          hidden.classList.remove('hide');
        } while (hidden = hidden.nextElementSibling);
        return;
      }

      if (icon.classList.contains("hide")) {
        line.classList.add('hide');
        return;
      }

      if (icon.classList.contains("language")) {
        const languages = speaks();
        setLang(line, editors[index], languages[(languages.indexOf(line.dataset.lang ?? 'sql') + 1) % languages.length]);
        return;
      }

      if (icon.classList.contains("render")) {
        const cycle = ['', ...Object.keys(RENDERERS)];
        const next = cycle[(cycle.indexOf(line.dataset.render ?? '') + 1) % cycle.length];
        if (next) line.dataset.render = next; else delete line.dataset.render;
        syncRender();
        paint(line);
        return;
      }

      if (icon.classList.contains("hamburger")) {
        Array.from(icon.parentElement.children).forEach(i => i.classList.remove('hidden') );
        icon.remove();
        return;
      }

      if (icon.classList.contains("remove")) {
        line.remove();
        editors.splice(index,1);
        return;
      }

      if (icon.classList.contains("split")) {

        const seperator = document.getElementById('engine').selectedOptions[0].dataset.separator;
        const statements = editors[index].state.doc.toString().split( (new RegExp(seperator,'im')) ).filter(s => s.trim());
        if(statements.length <= 1) return;
        replaceWith(line, statements.map(statement => statement.replace(/\s+$/,'').replace(/^\s+/,'')+(seperator===';'?';':'')));

        return;
      }

    }
  });

  for (const select of document.querySelectorAll('#engine, .version, .sample')) select.addEventListener('change', () => editors.forEach(e => e.setOffer(null)));

  document.getElementById('engine').addEventListener("change", event => {
    document.querySelector('.version:not(.hidden)').classList.add('hidden');
    const v = document.querySelector(`.version[data-engine=${event.target.value}]`);
    v.classList.remove('hidden');
    v.dispatchEvent(new Event('change'));
  });

  for (const v of document.querySelectorAll('.version')){
    v.addEventListener("change", event => {
      for (const s of document.querySelectorAll('.sample:not(.hidden)')) s.classList.add('hidden');
      for (const s of document.querySelectorAll(`.sample[data-engine="${v.dataset.engine}"][data-version="${event.target.value}"]`)) s.classList.remove('hidden');
      gate();
      document.querySelectorAll('.line').forEach((line,i) => {
        const lang = line.dataset.lang ?? 'sql';
        setLang(line, editors[i], speaks().includes(lang) ? lang : 'sql');
      });
      delete runButton.dataset.replacement;
      runButton.querySelector('span').textContent = 'run';
      runButton.disabled = false;
    });
  }

})();
