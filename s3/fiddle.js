(function() {

  const editors = [];
  const runButton = document.getElementById('run');
  const hashVals = window.location.hash ? window.location.hash.substring(1).split('.') : null;

  const engineCode = () => document.getElementById('engine').value;
  // 'sql' is the wire spelling of "no data-lang", never a value the runners see
  const speaks = () => (document.querySelector('.version:not(.hidden)').selectedOptions[0]?.dataset.languages ?? 'sql').split(',');
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

  // keys must match RENDERERS in site/fiddle/index.mjs, which allowlists the query string
  const RENDERERS = {
    echarts: {
      glyph: '#chart',
      global: 'echarts',
      parse: validateOption,
      draw: (div, option) => {
        const chart = echarts.init(div, null, { renderer: 'svg' });
        chart.setOption(option);
        // echarts sizes itself once at init and never again on its own
        new ResizeObserver(() => chart.resize()).observe(div);
      },
    },
  };

  const load = (src, global) => new Promise((ok, fail) => {
    if (window[global]) return ok();
    const s = document.createElement('script');
    s.src = src; s.onload = ok; s.onerror = () => fail(new Error(`could not load ${src}`));
    document.head.append(s);
  });

  const mark = line => {
    const name = line.dataset.render ?? '';
    const icon = line.querySelector('.render');
    icon.title = name ? `render: ${name}` : 'render';
    icon.querySelector('use').setAttribute('href', RENDERERS[name]?.glyph ?? '#chart');
  };

  const paint = async line => {
    const output = line.querySelector('.output');
    for (const stale of output.querySelectorAll('.chart, .render-error')) stale.remove();
    const pre = output.querySelector('pre');
    pre?.classList.remove('rendered');
    const name = line.dataset.render;
    if (!name || output.children.length === 0) return;
    const fail = message => {
      const error = document.createElement('code');
      error.className = 'language-error render-error';
      error.textContent = `${name}: ${message}`;
      (pre ?? output.lastElementChild).after(error);
    };
    if (!pre) return fail('nothing to render: expected a code block of printed output');
    try {
      const renderer = RENDERERS[name];
      const parsed = renderer.parse(pre.textContent);
      await load(document.querySelector('main').dataset[name], renderer.global);
      const div = document.createElement('div');
      div.className = 'chart';
      pre.before(div);
      pre.classList.add('rendered');
      renderer.draw(div, parsed);
    } catch (e) {
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

  for (const line of document.querySelectorAll('.line[data-render]')) {
    mark(line);
    paint(line);
  }

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
    editors.forEach((e,i) => { if(e.state.doc.toString()==='') remove.push(document.querySelectorAll('.line')[i].querySelector('.icon.remove')) });
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
        mark(line);
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
        let plus = line.querySelector('.plus:first-child');
        for (const [i,statement] of statements.entries()){
          document.querySelector('template').content.querySelector('textarea').value = statement.replace(/\s+$/,'').replace(/^\s+/,'')+(seperator===';'?';':'');
          plus.click();
          document.querySelector('template').content.querySelector('textarea').value = '';
        }
        icon.parentElement.querySelector('.remove').click();

        return;
      }

    }
  });

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
