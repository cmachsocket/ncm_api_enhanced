// NcmApi: typed-ish facade for @neteasecloudmusicapienhanced/api.
//
// Every upstream module filename stem (e.g. "album", "login_qr_key",
// "user_account") is callable as a method on [NcmApi]:
//
//     await api.album({'id': 12345});
//     await api.userAccount();
//     await api.loginQrKey({'type': 1});
//
// Calls are forwarded to the embedded node bridge as a single JSON-RPC
// request and return the upstream Response body, unchanged in shape:
//
//     { "status": 200, "body": { "code": 200, ... }, "cookie": ["..."] }
//
// Upstream business errors (e.g. {code: 502} on bad login) come back as a
// *resolved* map whose `body.code` is non-200 — they are NOT thrown.
// Protocol/bridge errors (process died, IPC broken, timeout) DO throw
// [BridgeError] / [TimeoutException].
//
// All calls go through the same [_bridge] Future pipeline, so issuing N
// requests without awaiting them runs them concurrently on the node event
// loop.

import 'dart:async';

import 'bridge.dart';
import 'platform_bridge.dart';

class NcmApi {
  NcmApi({NcmBridge? bridge}) : _bridge = bridge ?? NcmBridgeFactory.build();

  /// Exposed for advanced users (e.g. swapping the bridge at runtime,
  /// listening to bridge events, shutting down explicitly).
  final NcmBridge _bridge;

  /// Underlying bridge. Useful for: subscribing to `events` (logs, fatals),
  /// calling `shutdown()` cleanly on app teardown.
  NcmBridge get bridge => _bridge;

  /// Start the embedded node runtime. Must be awaited before any API call.
  Future<void> start() => _bridge.start();

  /// Graceful shutdown. Tears down the node child process (desktop) or
  /// closes the platform channel (mobile).
  Future<void> shutdown() => _bridge.shutdown();

  /// Subscribe to bridge-side logs and fatal events.
  Stream<Map<String, dynamic>> get bridgeEvents => _bridge.events;

  /// Forward a raw call. Useful for module names that aren't valid Dart
  /// identifiers, or when you want to call dynamically.
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    _assertKnown(method);
    return _bridge.call(method, params);
  }

  // ---------------------------------------------------------------------------
  // Dynamic method dispatch
  // ---------------------------------------------------------------------------

  /// Every supported upstream module function name. Used to validate that
  /// a typo'd method name fails fast instead of silently hitting the
  /// "unknown method" path on the node side.
  static const Set<String> _methodNames = <String>{
      'activate_init_profile',   'ad_get',   'ad_listening_rights',   'ad_listening_rights_gain',   'aidj_content_rcmd',   'album',   'album_detail',   'album_detail_dynamic',   'album_list',   'album_list_style',   'album_new',   'album_newest',
      'album_privilege',   'album_songsaleboard',   'album_sub',   'album_sublist',   'api',   'artist_album',   'artist_desc',   'artist_detail',   'artist_detail_dynamic',   'artist_fans',   'artist_follow_count',   'artist_list',
      'artist_mv',   'artist_new_mv',   'artist_new_song',   'artist_new_song_mv_list_v2',   'artist_new_song_playall',   'artist_songs',   'artist_sub',   'artist_sublist',   'artist_top_song',   'artist_video',   'artists',   'audio_match',
      'avatar_upload',   'banner',   'batch',   'broadcast_category_region_get',   'broadcast_channel_collect_list',   'broadcast_channel_currentinfo',   'broadcast_channel_list',   'broadcast_sub',   'calendar',   'captcha_safe_sent',   'captcha_sent',   'captcha_sent_v1',
      'captcha_verify',   'cellphone_existence_check',   'chart_detail',   'chart_song_detail',   'check_music',   'cloud',   'cloud_import',   'cloud_lyric_get',   'cloud_match',   'cloud_upload_complete',   'cloud_upload_token',   'cloudsearch',
      'comment',   'comment_add',   'comment_album',   'comment_delete',   'comment_dj',   'comment_event',   'comment_floor',   'comment_hot',   'comment_hug_list',   'comment_info_list',   'comment_like',   'comment_music',
      'comment_mv',   'comment_new',   'comment_playlist',   'comment_reply',   'comment_report',   'comment_video',   'countries_code_list',   'creator_authinfo_get',   'daily_signin',   'decrypt',   'device_kickoff',   'device_list',
      'digitalAlbum_detail',   'digitalAlbum_ordering',   'digitalAlbum_purchased',   'digitalAlbum_sales',   'djRadio_top',   'dj_banner',   'dj_category_excludehot',   'dj_category_recommend',   'dj_catelist',   'dj_detail',   'dj_difm_all_style_channel',   'dj_difm_channel_subscribe',
      'dj_difm_channel_unsubscribe',   'dj_difm_playing_tracks_list',   'dj_difm_subscribe_channels_get',   'dj_hot',   'dj_paygift',   'dj_personalize_recommend',   'dj_program',   'dj_program_detail',   'dj_program_toplist',   'dj_program_toplist_hours',   'dj_radio_hot',   'dj_recommend',
      'dj_recommend_type',   'dj_sub',   'dj_sublist',   'dj_subscriber',   'dj_today_perfered',   'dj_toplist',   'dj_toplist_hours',   'dj_toplist_newcomer',   'dj_toplist_pay',   'dj_toplist_popular',   'eapi_decrypt',   'event',
      'event_del',   'event_forward',   'event_privacy',   'fanscenter_basicinfo_age_get',   'fanscenter_basicinfo_gender_get',   'fanscenter_basicinfo_province_get',   'fanscenter_overview_get',   'fanscenter_trend_list',   'fm_trash',   'follow',   'get_userids',   'history_recommend_songs',
      'history_recommend_songs_detail',   'homepage_block_page',   'homepage_dragon_ball',   'hot_topic',   'hug_comment',   'inner_version',   'lbs_city_code',   'like',   'like_v1',   'likelist',   'listen_data_realtime_report',   'listen_data_report',
      'listen_data_song_play_rank',   'listen_data_today_song',   'listen_data_total',   'listen_data_year_report',   'listentogether_accept',   'listentogether_end',   'listentogether_heatbeat',   'listentogether_play_command',   'listentogether_room_check',   'listentogether_room_create',   'listentogether_status',   'listentogether_sync_list_command',
      'listentogether_sync_playlist_get',   'login',   'login_cellphone',   'login_qr_check',   'login_qr_create',   'login_qr_key',   'login_refresh',   'login_status',   'logout',   'lyric',   'lyric_new',   'middle_play_do_lottery',
      'middle_play_lottery_remain_chance',   'mlog_music_rcmd',   'mlog_to_video',   'mlog_url',   'msg_comments',   'msg_forwards',   'msg_notices',   'msg_private',   'msg_private_history',   'msg_recentcontact',   'music_first_listen_info',   'musician_cloudbean',
      'musician_cloudbean_obtain',   'musician_data_overview',   'musician_play_trend',   'musician_sign',   'musician_tasks',   'musician_tasks_new',   'musician_vip_tasks',   'mv_all',   'mv_detail',   'mv_detail_info',   'mv_exclusive_rcmd',   'mv_first',
      'mv_sub',   'mv_sublist',   'mv_url',   'nickname_check',   'personal_fm',   'personal_fm_mode',   'personalized',   'personalized_djprogram',   'personalized_mv',   'personalized_newsong',   'personalized_privatecontent',   'personalized_privatecontent_list',
      'pl_count',   'playlist_category_list',   'playlist_catlist',   'playlist_cover_update',   'playlist_create',   'playlist_delete',   'playlist_desc_update',   'playlist_detail',   'playlist_detail_dynamic',   'playlist_detail_rcmd_get',   'playlist_highquality_tags',   'playlist_hot',
      'playlist_import_name_task_create',   'playlist_import_task_status',   'playlist_mylike',   'playlist_name_update',   'playlist_order_update',   'playlist_privacy',   'playlist_subscribe',   'playlist_subscribers',   'playlist_tags_update',   'playlist_track_add',   'playlist_track_all',   'playlist_track_delete',
      'playlist_tracks',   'playlist_update',   'playlist_update_playcount',   'playlist_video_recent',   'playmode_intelligence_list',   'playmode_song_vector',   'program_recommend',   'radio_sport_get',   'rebind',   'recent_listen_list',   'recommend_resource',   'recommend_songs',
      'recommend_songs_dislike',   'record_recent_album',   'record_recent_dj',   'record_recent_playlist',   'record_recent_song',   'record_recent_video',   'record_recent_voice',   'register_anonimous',   'register_cellphone',   'register_checktoken_v2',   'register_checktoken_v3',   'register_xeapikey',
      'related_allvideo',   'related_playlist',   'relay_play_state_submit',   'rep_ugc_activity_collect',   'rep_ugc_activity_get',   'rep_ugc_exam_info_get',   'rep_ugc_exam_question_single_get',   'rep_ugc_exam_result_get',   'rep_ugc_exam_start',   'rep_ugc_exam_submit',   'rep_ugc_user_collect-vip',   'rep_ugc_user_get',
      'rep_ugc_user_sign',   'rep_ugc_user_vip',   'resource_like',   'sati_resource_list',   'sati_resource_list_more',   'sati_resource_sub',   'sati_resource_sub_list',   'sati_tag_list',   'sati_timescene_resources_get',   'scrobble',   'scrobble_v1',   'search',
      'search_default',   'search_hot',   'search_hot_detail',   'search_match',   'search_multimatch',   'search_suggest',   'search_suggest_pc',   'send_album',   'send_playlist',   'send_song',   'send_text',   'setting',
      'share_resource',   'sheet_list',   'sheet_preview',   'sign_happy_info',   'signin_progress',   'simi_artist',   'simi_mv',   'simi_playlist',   'simi_song',   'simi_user',   'song_chorus',   'song_cloud_download',
      'song_copyright_rcmd',   'song_creators',   'song_detail',   'song_downlist',   'song_download_url',   'song_download_url_v1',   'song_dynamic_cover',   'song_like',   'song_like_check',   'song_lyrics_mark',   'song_lyrics_mark_add',   'song_lyrics_mark_del',
      'song_lyrics_mark_user_page',   'song_monthdownlist',   'song_music_detail',   'song_order_update',   'song_purchased',   'song_red_count',   'song_simi_get',   'song_singledownlist',   'song_url',   'song_url_match',   'song_url_ncmget',   'song_url_v1',
      'song_url_v1_302',   'song_wiki_info',   'song_wiki_summary',   'starpick_comments_summary',   'style_album',   'style_artist',   'style_detail',   'style_list',   'style_playlist',   'style_preference',   'style_song',   'summary_annual',
      'thinktank_audit_resource_detail',   'thinktank_audit_resource_update',   'threshold_detail_get',   'top_album',   'top_artists',   'top_list',   'top_mv',   'top_playlist',   'top_playlist_highquality',   'top_song',   'topic_detail',   'topic_detail_event_hot',
      'topic_sublist',   'toplist',   'toplist_artist',   'toplist_detail',   'toplist_detail_v2',   'ugc_album_get',   'ugc_artist_get',   'ugc_artist_search',   'ugc_detail',   'ugc_mv_get',   'ugc_song_get',   'ugc_user_devote',
      'user_account',   'user_audio',   'user_binding',   'user_bindingcellphone',   'user_cloud',   'user_cloud_del',   'user_cloud_detail',   'user_comment_history',   'user_detail',   'user_detail_new',   'user_dj',   'user_event',
      'user_event_all',   'user_follow_mixed',   'user_followeds',   'user_follows',   'user_level',   'user_medal',   'user_mutualfollow_get',   'user_playlist',   'user_playlist_collect',   'user_playlist_create',   'user_record',   'user_replacephone',
      'user_social_status',   'user_social_status_edit',   'user_social_status_rcmd',   'user_social_status_support',   'user_subcount',   'user_update',   'verify_getQr',   'verify_qrcodestatus',   'video_category_list',   'video_detail',   'video_detail_info',   'video_group',
      'video_group_list',   'video_sub',   'video_timeline_all',   'video_timeline_recommend',   'video_url',   'vip_growthpoint',   'vip_growthpoint_details',   'vip_growthpoint_get',   'vip_growthpoint_getall',   'vip_info',   'vip_info_v2',   'vip_sign',
      'vip_sign_detail',   'vip_sign_history',   'vip_sign_info',   'vip_tasks',   'vip_tasks_v1',   'vip_timemachine',   'voice_delete',   'voice_detail',   'voice_lyric',   'voice_upload',   'voicelist_detail',   'voicelist_list',
      'voicelist_list_search',   'voicelist_my_created',   'voicelist_search',   'voicelist_trans',   'weblog',   'yunbei',   'yunbei_expense',   'yunbei_info',   'yunbei_rcmd_song',   'yunbei_rcmd_song_history',   'yunbei_receipt',   'yunbei_sign',
      'yunbei_task_finish',   'yunbei_task_finish_v1',   'yunbei_task_list_v1',   'yunbei_task_recommend_song',   'yunbei_tasks',   'yunbei_tasks_todo',   'yunbei_today',  };

  static void _assertKnown(String method) {
    if (!_methodNames.contains(method)) {
      throw ArgumentError(
        'NcmApi: "$method" is not a known upstream module. '
        'Check the upstream @neteasecloudmusicapienhanced/api/module/ '
        'directory for valid names, or use api.call("$method", params).',
      );
    }
  }

  /// Maps a Dart-style method name back to the upstream module name. Most
  /// modules are snake_case already, but a few upstream names contain
  /// characters (e.g. hyphens) that are awkward to call from Dart — those
  /// are added to [_nameAliases].
  static const Map<String, String> _nameAliases = <String, String>{
    // Add entries here for any module that needs Dart-side renaming.
    // Example: if upstream is `foo-bar`, use 'fooBar': 'foo-bar',
  };

  /// Resolve a Dart method name to its upstream module name.
  static String _resolve(String dartName) {
    return _nameAliases[dartName] ?? dartName;
  }

  /// Dynamic dispatch. Lets callers write `api.album(...)` for any of the
  /// 439 upstream modules without us having to hand-write a wrapper for
  /// each one.
  ///
  /// Supported invocations:
  ///   api.album()                       // no-arg
  ///   api.album(params)                 // single map arg
  ///   api.album(id: 12345, cookie: '...') // named/positional
  ///
  /// Returns a `Future<Map<String, dynamic>>` — same shape as [call].
  ///
  /// Implementation note: we route ALL non-Object method calls through here.
  /// To avoid intercepting Object protocol methods (`toString`, `==`, etc.),
  /// we explicitly bail out to super.noSuchMethod for those.
  @override
  @pragma('vm:entry-point')
  dynamic noSuchMethod(Invocation invocation) {
    final raw = invocation.memberName.toString();
    // invocation.memberName.toString() looks like `Symbol("foo")`.
    final name = raw.startsWith('Symbol("') && raw.endsWith('")')
        ? raw.substring(8, raw.length - 2)
        : raw;
    if (_objectMembers.contains(name)) {
      return super.noSuchMethod(invocation);
    }

    final methodName = _resolve(name);

    final Map<String, dynamic> params = <String, dynamic>{};
    if (invocation.positionalArguments.isNotEmpty) {
      final p = invocation.positionalArguments.first;
      if (p is Map) {
        params.addAll(p.cast<String, dynamic>());
      } else {
        throw ArgumentError(
          'NcmApi.$methodName: positional arg must be a Map<String, dynamic>; got ${p.runtimeType}',
        );
      }
    }
    // invocation.namedArguments is `Map<Symbol, dynamic>`; convert each key
    // back to its identifier name (the upstream module keys are always
    // bare identifiers, so the Symbol-to-String conversion is lossless).
    invocation.namedArguments.forEach((sym, value) {
      params[sym.toString()] = value;
    });

    _assertKnown(methodName);
    return _bridge.call(methodName, params.isEmpty ? null : params);
  }

  /// Method names defined on [Object] that should bypass the dynamic
  /// dispatch and fall through to Object's default behavior. Otherwise we
  /// would intercept `==`, `hashCode`, `toString`, etc., and `api == other`
  /// would try to look up a method called `==`.
  static const Set<String> _objectMembers = <String>{
    '==', 'hashCode', 'toString', 'noSuchMethod', 'runtimeType',
    // From the dart:core / dart:ui protocols invoked by tooling/serializers:
    'toJson', 'toJsonString',
  };
}
