#!/usr/bin/env python3
"""Produit des sources corrigés depuis le SHA Tymeslot audité ; n'édite pas l'amont."""
import argparse
from pathlib import Path
import subprocess

SHA = '0ae102c8f89f744f712e7139e72de7f6284b9179'


def preparer(source, destination):
    source, destination = Path(source), Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    def read(path):
        return subprocess.check_output(['git', '-C', str(source), 'show', SHA + ':' + path], text=True)
    def save(name, text):
        (destination / name).write_text(text.replace('Tymeslot.HQ.Identites.', 'Tymeslot.Mailer.hq_'))
    def replace(text, old, new, count=1):
        assert text.count(old) == count, 'Préimage inattendue : ' + old[:70]
        return text.replace(old, new)

    s = read('lib/tymeslot_web/controllers/healthcheck_controller.ex')
    bridge = Path(__file__).with_name('pont_hq.ex').read_text()
    save('healthcheck_controller.ex', s.rstrip()[:-3] + bridge + '\nend\n')
    s = read('lib/tymeslot_web/router.ex')
    s = replace(s, '    get "/healthcheck", HealthcheckController, :index',
        '    get "/healthcheck", HealthcheckController, :index\n    get "/internal/hq/booking", HealthcheckController, :hq\n    post "/internal/hq/booking", HealthcheckController, :hq')
    save('router.ex', s)

    s = read('lib/tymeslot/integrations/calendar/caldav/http.ex')
    s = replace(s, 'authed_request("DELETE", url, username, password, [], fn headers ->',
        'authed_request("DELETE", url, username, password, (if opts[:if_match], do: [{"If-Match", opts[:if_match]}], else: []), fn headers ->')
    s = replace(s, 'classify(response, :delete, url, success: [200, 204, 404])',
        'classify(response, :delete, url, success: [200, 204, 404], status_overrides: %{412 => :precondition_failed})')
    save('caldav_http.ex', s)
    s = read('lib/tymeslot/integrations/calendar/caldav/events.ex')
    s = replace(s, 'delete_opts = Keyword.take(opts, [:timeout])', 'delete_opts = Keyword.take(opts, [:timeout, :if_match])')
    save('caldav_events.ex', s)

    s = read('lib/tymeslot/bookings/create.ex')
    s = replace(s, '# Calendar transport/timeout errors - log but don\'t block booking\n        # The booking will succeed and calendar sync will be retried in background',
        '# HQ: an unreadable calendar never means the host is free.')
    s = replace(s, 'Calendar availability check failed, proceeding with booking', 'Calendar availability check failed, refusing booking')
    s = replace(s, '        {:ok, :validated}\n    end\n  end\n\n  defp fresh_calendar_check', '        {:error, :availability_unverifiable}\n    end\n  end\n\n  defp fresh_calendar_check')
    s = s.replace('Calendar availability check timed out after 5s, proceeding with booking', 'Calendar availability check timed out after 5s, refusing booking')
    s = s.replace("# want to block the user if calendar is slow. If it times out, we proceed anyway.", '# refuse confirmation when the calendar cannot be verified in time.')
    save('create.ex', s)

    s = read('lib/tymeslot/bookings/reschedule.ex')
    s = replace(s, '         {:ok, new_times} <- prepare_new_times(new_params, original_meeting, meeting_type),',
        '         {:ok, new_times} <- prepare_new_times(new_params, original_meeting, meeting_type),\n         :ok <- hq_check_calendar(original_meeting, new_times, meeting_type),')
    helper = '''  # HQ: a move checks the other connected calendars as well as local bookings.
  defp hq_check_calendar(meeting, times, type) do
    config = Policy.scheduling_config(meeting.organizer_user_id, type)
    from = DateTime.add(times.start_time, -config.buffer_minutes, :minute)
    until = DateTime.add(times.end_time, config.buffer_minutes, :minute)
    task = Task.Supervisor.async_nolink(Tymeslot.TaskSupervisor, fn ->
      Tymeslot.Integrations.Calendar.Events.get_events_for_range_fresh(
        meeting.organizer_user_id, from, until)
    end)
    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, events}} ->
        events = Enum.reject(events, fn event -> Map.get(event, :uid) == meeting.uid end)
        case Validation.validate_no_conflicts(times.start_time, times.end_time, events, config) do
          :ok -> :ok
          _ -> {:error, :slot_taken}
        end
      _ -> {:error, :slot_taken}
    end
  end

'''
    s = replace(s, '  # Private functions\n', helper + '  # Private functions\n')
    save('reschedule.ex', s)

    s = read('lib/tymeslot/integrations/calendar/runtime/client_manager.ex')
    s = replace(s, '''      %MeetingSchema{calendar_integration_id: integration_id, organizer_user_id: user_id}
      when is_integer(integration_id) ->
        get_client_by_integration_id(integration_id, user_id)''', '''      %MeetingSchema{calendar_integration_id: integration_id, organizer_user_id: user_id} = meeting
      when is_integer(integration_id) and is_binary(meeting.calendar_path) and meeting.calendar_path != "" ->
        # HQ: updates/deletions must use the calendar persisted at booking time.
        case CalendarManagement.fetch_integration_for_user(integration_id, user_id) do
          {:ok, integration} when integration.is_active ->
            booking_client_for_integration(%{integration |
              default_booking_calendar_id: meeting.calendar_path, calendar_paths: [meeting.calendar_path]})
          _ -> nil
        end''')
    s = replace(s, '''      %MeetingSchema{organizer_user_id: user_id} when is_integer(user_id) ->
        client(user_id)''', '''      %MeetingSchema{} ->
        nil''')
    save('client_manager.ex', s)

    s = read('lib/tymeslot/meetings/scheduling.ex')
    # Le verrou existe même lorsque la requête de conflits ne renvoie aucune ligne.
    s = replace(s, '    Repo.transaction(fn ->\n      with :ok <- enforce_booking_limits(limit_check),',
        '    Repo.transaction(fn ->\n      lock_host(organizer_user_id)\n      with :ok <- enforce_booking_limits(limit_check),', 2)
    # La transaction de déplacement possède l'hôte sur meeting, pas dans une variable locale.
    marker = '  defp execute_update_with_conflict_check'
    before, after = s.split(marker, 1)
    after = after.replace('lock_host(organizer_user_id)', 'lock_host(meeting.organizer_user_id)', 1)
    s = before + marker + after
    insertion = '''  defp lock_host(id) when is_integer(id),
    do: MeetingConflictQueries.acquire_booking_limits_lock(id)
  defp lock_host(_), do: raise("Organizer required for conflict protection")

'''
    s = replace(s, '  # nil means limits are not applicable to this call', insertion + '  # nil means limits are not applicable to this call')
    save('scheduling.ex', s)

    s = read('lib/tymeslot/bookings/policy.ex')
    s = replace(s, '{org_name, org_email, org_username} = get_organizer_details(organizer_user_id)',
        '{org_name, org_email, org_username} = Tymeslot.HQ.Identites.organiser(meeting_type_record, get_organizer_details(organizer_user_id))')
    save('policy.ex', s)

    s = read('lib/tymeslot/emails/shared/mjml_email.ex')
    s = replace(s, '|> from({fetch_from_name(), fetch_from_email()})',
        '|> from({fetch_from_name(), fetch_from_email()})\n    |> Tymeslot.HQ.Identites.email(Keyword.get(opts, :organizer))')
    save('mjml_email.ex', s)

    s = read('lib/tymeslot/mailer.ex')
    s = replace(s, '    email\n    |> apply_tracking(config)\n    |> super(config)',
        '    with {:ok, config} <- Tymeslot.HQ.Identites.delivery(email, config) do\n      email\n      |> apply_tracking(config)\n      |> super(config)\n    end')
    # Une release Erlang embarquée ne charge que ses modules déclarés au boot.
    # Les fonctions sont compilées dans le Mailer déjà présent, sans hotpatch.
    identities = Path(__file__).with_name('identites.ex').read_text()
    body = identities[identities.index('  def enabled?'):identities.rindex('\nend')]
    body = body.replace('enabled?', 'hq_enabled?').replace('config!', 'hq_config!')
    body = body.replace('def organiser(', 'def hq_organiser(').replace('def email(', 'def hq_email(').replace('def delivery(', 'def hq_delivery(')
    s = s[:s.rindex('\nend')] + '\n' + body + '\nend\n'
    save('mailer.ex', s)
    for name in ['appointment_confirmation', 'appointment_reminder', 'appointment_rescheduled', 'appointment_cancellation',
                 'booking_request_received', 'booking_approval_request', 'booking_request_outcome', 'reschedule_request']:
        s = read('lib/tymeslot/emails/templates/' + name + '.ex')
        variable = 'appointment_details' if name.startswith('appointment_') else 'meeting'
        assert 'MjmlEmail.base_email()' in s
        s = s.replace('MjmlEmail.base_email()', 'MjmlEmail.base_email(organizer: ' + variable + ')')
        s = s.replace('      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})\n', '')
        save(name + '.ex', s)
    save('SOURCE.txt', 'https://github.com/Tymeslot/tymeslot\n' + SHA + '\nLicence AGPL-3.0\n')
    print('Sources corrigés préparés depuis la révision épinglée.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    preparer(args.source, args.destination)
