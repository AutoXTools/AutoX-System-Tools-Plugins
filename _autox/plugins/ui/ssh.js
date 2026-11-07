// AutoX ES5 Web UI Controller for SSH Remote Access (ssh)
// Target Platform: Mazda Connect Opera 12 Browser (FW 74.00.324)

(function() {
  'use strict';

  function initPlugin() {
    var container = document.getElementById('plugin-ssh-card');
    if (!container) return;

    var btnToggle = container.querySelector('.btn-toggle');
    if (btnToggle) {
      btnToggle.addEventListener('click', function() {
        var isEnabled = btnToggle.getAttribute('data-enabled') === 'true';
        var action = isEnabled ? 'disable' : 'enable';
        
        if (window.AutoXBus) {
          window.AutoXBus.sendAction('ssh', action, function(err, response) {
            if (!err) {
              btnToggle.setAttribute('data-enabled', isEnabled ? 'false' : 'true');
              btnToggle.textContent = isEnabled ? 'Enable' : 'Active';
            }
          });
        }
      });
    }
  }

  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    initPlugin();
  } else {
    document.addEventListener('DOMContentLoaded', initPlugin);
  }
})();
