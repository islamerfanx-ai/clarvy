-- The file tools count against a daily limit of their own ('file'); the list of kinds didn't include it,
-- so every file action failed. Add it.
alter table usage_counts drop constraint usage_counts_kind_check;
alter table usage_counts add constraint usage_counts_kind_check
  check (kind in ('triage', 'criteria', 'decide', 'roles', 'question', 'brief', 'helper', 'notes', 'simulate', 'research', 'file'));
