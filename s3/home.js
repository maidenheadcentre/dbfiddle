(function() {
  document.querySelectorAll('input[name="version"]').forEach(input => {
    input.addEventListener("change", async function(ev) {
      document.querySelectorAll('table+table').forEach(table => {
        if(input.value === table.dataset.engine) {
          table.removeAttribute('hidden');
        } else {
          table.setAttribute('hidden','');
        }
      });
    });
  });
})();