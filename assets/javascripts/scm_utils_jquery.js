var force_repository_module = function() {
  var r = $('#project_enabled_module_names_repository');
  if (r.length) {
    r.prop('checked', true);
    r.prop('disabled', true);
  }
};
var toggle_project_scm_visibility = function() {
  if ($('#project_enabled_module_names_repository').is(':checked')) {
    $('#project_scm').show();
  } else {
    $('#project_scm').hide();
  }
};
