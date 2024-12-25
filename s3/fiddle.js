(function() {

  const editors = [];
  const runButton = document.getElementById('run');
  const hashVals = window.location.hash ? window.location.hash.substring(1).split('.') : null;

  history.replaceState("", document.title, window.location.pathname + window.location.search);

  for (const textarea of document.querySelectorAll('textarea')) {
    editors.push(cm.editorFromTextArea(textarea, document.getElementById('engine').value));
  }

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

  runButton.addEventListener('click', async e => {

    const remove = [];
    editors.forEach((e,i) => { if(e.state.doc.toString()==='') remove.push(document.querySelectorAll('.line')[i].querySelector('.icon.remove')) });
    remove.forEach(e => e.click());

    const batches = [];
    const hide = parseInt(Array.from(document.querySelectorAll('.line')).reduce((p,c,i) => p + (c.classList.contains('hide')?'1':'0'), '' ),2);
    const highlight = parseInt(Array.from(document.querySelectorAll('.line')).reduce((p,c,i) => p + (c.classList.contains('highlight')?'1':'0'), '' ),2);
    let hash = '';

    for (const [index, editor] of editors.entries()){
      editor.setEditable(false);
      batches.push(editor.state.doc.toString());
      if(editor.dom.classList.contains('cm-focused')) hash = `#${index}.${editor.state.selection.ranges[0].from}`;
    }

    let query = '?engine=' + document.getElementById('engine').value + '&version=' + document.querySelector('.version:not(.hidden)').value;
    const sampleElement = document.querySelector('.sample:not(.hidden)');
    if( (sampleElement !== null) && (sampleElement.value !== '') ) query += '&sample=' + sampleElement.value;

    runButton.disabled = true;
    runButton.classList.add('running');

    let aborted = false;

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
        body: JSON.stringify(batches),
        signal: controller.signal,
      }).then(response => {
        if (response.status !== 200) throw new Error("Bad response");
        return response;
      });

      const params = new URLSearchParams();
      if(hide) params.append('hide',hide);
      if(highlight) params.append('highlight',highlight);

      history.pushState("", document.title, (await response.text()) + (params.toString() ? '?' + params.toString() : '') + hash);
      window.location.reload();

    } catch (e) {
      if(!aborted) alert('run failed');
    } finally {
      for (const editor of editors) editor.setEditable(true);
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
        const editor = cm.editorFromTextArea(clone.querySelector('textarea'),document.getElementById('engine').value);
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

      if (icon.classList.contains("highlight")) {
        line.classList.toggle('highlight');
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
      runButton.disabled = false;
    });
  }

})();