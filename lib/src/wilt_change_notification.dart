/*
 * Packge : Wilt
 * Author : S. Hamblett <steve.hamblett@linux.com>
 * Date   : 07/01/2014
 * Copyright :  S.Hamblett@OSCF
 *
 * Change notification control class
 * 
 */

part of wilt;

// ignore_for_file: omit_local_variable_types
// ignore_for_file: unnecessary_final
// ignore_for_file: cascade_invocations
// ignore_for_file: avoid_print
// ignore_for_file: avoid_annotating_with_dynamic

/// This class initiates change notification processing with either
/// a default set of change notification parameters or one supplied by
/// the client. When destroyed, change notification ceases.
///
/// The resulting notifications are turned into notification events and
/// streamed to the notification consumer. as a stream of
/// WiltChangeNotificationEvent objects, see
/// [WiltChangeNotificationEvent] class for further details.
///
/// CouchDb is initialized to supply the change notification stream in
/// 'normal' mode, hence this class requests the updates manually on a
/// timed basis dependent on the heartbeat period.
///
/// Note that as from CouchDB 1.6.1 you must auth as an administrator
/// with CouchDb to allow notificatons to work, if you do not supply
/// auth credentials before starting notifications an exception is raised.
class _WiltChangeNotification {
  _WiltChangeNotification(
      this._host, this._port, this._scheme, this._httpAdapter,
      [this._dbName, this.parameters]) {
    parameters ??= WiltChangeNotificationParameters();

    _sequence = parameters.since;

    // Start the heartbeat timer
    final Duration heartbeat = Duration(milliseconds: parameters.heartbeat);
    _timer = Timer.periodic(heartbeat, _requestChanges);

    // Start change notifications
    _requestChanges(_timer);
  }

  /// Parameters set
  WiltChangeNotificationParameters parameters;

  /// Database name
  final String _dbName;

  /// Host name
  final String _host;

  /// Port number
  final String _port;

  /// HTTP scheme
  final String _scheme;

  /// Timer
  Timer _timer;

  /// Since sequence update
  dynamic _sequence = 0;

  /// Paused indicator
  bool paused = false;

  final WiltHTTPAdapter _httpAdapter;

  /// Change notification stream controller
  ///
  /// Populated with WiltChangeNotificationEvent events
  final StreamController<WiltChangeNotificationEvent> _changeNotification =
      StreamController<WiltChangeNotificationEvent>.broadcast();

  StreamController<WiltChangeNotificationEvent> get changeNotification =>
      _changeNotification;

  /// Request the change notifications
  void _requestChanges(Timer timer) {
    if (paused) {
      return;
    }

    // Create the URL from the parameters
    String path;
    if (_sequence != null) {
      path =
          '$_dbName/_changes?&since=$_sequence&descending=${parameters.descending}&include_docs=${parameters.includeDocs}&attachments=${parameters.includeAttachments}';
    } else {
      path =
          '$_dbName/_changes?&descending=${parameters.descending}&include_docs=${parameters.includeDocs}&attachments=${parameters.includeAttachments}';
    }

    final String url = '$_scheme$_host:${_port.toString()}/$path';

    // Open the request
    try {
      _httpAdapter.getString(url).then((dynamic result) {
        // Process the change notification
        try {
          final Map<dynamic, dynamic> dbChange = json.decode(result);
          processDbChange(dbChange);
        } on Exception catch (e) {
          // Recoverable error, send the client an error event
          print('WiltChangeNotification::MonitorChanges json decode fail $e');
          final WiltChangeNotificationEvent notification =
              WiltChangeNotificationEvent.decodeError(result, e.toString());

          _changeNotification.add(notification);
        }
      });
    } on Exception catch (e) {
      // Unrecoverable error, send the client an abort event
      print('WiltChangeNotification::MonitorChanges unable to contact '
          'CouchDB Error is $e');
      final WiltChangeNotificationEvent notification =
          WiltChangeNotificationEvent.abort(e.toString());

      _changeNotification.add(notification);
    }
  }

  /// Database change updates
  void processDbChange(Map<String, dynamic> change) {
    // Check for an error response
    if (change.containsKey('error')) {
      final WiltChangeNotificationEvent notification =
          WiltChangeNotificationEvent.couchDbError(
              change['error'], change['reason']);

      _changeNotification.add(notification);

      return;
    }

    // Update the last sequence number
    _sequence = WiltUserUtils.getCnSequenceNumber(change['last_seq']);

    // Process the result list
    final List<dynamic> results = change['results'];
    if (results.isEmpty) {
      final WiltChangeNotificationEvent notification =
          WiltChangeNotificationEvent.sequence(_sequence);

      _changeNotification.add(notification);

      return;
    }

    for (final dynamic result in results) {
      final Map<String, dynamic> changes = result['changes'][0];

      // Check for delete or update
      if (result.containsKey('deleted')) {
        final WiltChangeNotificationEvent notification =
            WiltChangeNotificationEvent.delete(result['id'], changes['rev'],
                WiltUserUtils.getCnSequenceNumber(result['seq']));

        _changeNotification.add(notification);
      } else {
        dynamic document;
        if (result.containsKey('doc')) {
          document = jsonobject.JsonObjectLite<dynamic>.fromJsonString(
              WiltUserUtils.mapToJson(result['doc']));
        }
        final WiltChangeNotificationEvent notification =
            WiltChangeNotificationEvent.update(result['id'], changes['rev'],
                WiltUserUtils.getCnSequenceNumber(result['seq']), document);

        _changeNotification.add(notification);
      }
    }
  }

  /// Stop change notifications
  void stopNotifications() {
    _timer.cancel();
  }

  /// Restart change notifications
  void restartChangeNotifications() {
    // Start the heartbeat timer
    final Duration heartbeat = Duration(milliseconds: parameters.heartbeat);
    _timer = Timer.periodic(heartbeat, _requestChanges);

    // Start change notifications
    _requestChanges(_timer);
  }
}
