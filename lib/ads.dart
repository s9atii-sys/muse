import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'core.dart';

class AdClock {
  final double interstitialSeconds, rewardSeconds, rewardDuration;
  double sinceInterstitial = 0, sinceReward = 0, adFree = 0;
  bool showing = false;
  AdClock({
    this.interstitialSeconds = 15,
    this.rewardSeconds = 60,
    this.rewardDuration = 120,
  });
  bool get interstitialEligible =>
      !showing && adFree <= 0 && sinceInterstitial >= interstitialSeconds;
  bool get rewardEligible =>
      !showing && adFree <= 0 && sinceReward >= rewardSeconds;
  void tick(double seconds, {bool active = true}) {
    if (!active || showing || !seconds.isFinite || seconds <= 0) return;
    sinceInterstitial += seconds;
    sinceReward += seconds;
    adFree = math.max(0, adFree - seconds);
  }

  void start() {
    showing = true;
  }

  void finish() {
    showing = false;
    sinceInterstitial = 0;
  }

  void earned() {
    adFree = rewardDuration;
    sinceReward = 0;
    sinceInterstitial = 0;
  }
}

class MuseAds extends ChangeNotifier with WidgetsBindingObserver {
  final Json config;
  late final AdClock clock;
  InterstitialAd? _interstitial;
  RewardedAd? _rewarded;
  Timer? _timer, _iRetry, _rRetry;
  bool _closed = false,
      _started = false,
      _foreground = true,
      _consentBusy = false,
      _canRequest = false;
  int _generation = 0, _iFailures = 0, _rFailures = 0;
  bool privacyRequired = false;
  String status = 'Ads disabled on this platform';
  final Stopwatch _watch = Stopwatch();
  double _last = 0;
  MuseAds(this.config) {
    clock = AdClock(
      interstitialSeconds: numv(
        config['interstitialSeconds'],
        15,
      ).clamp(15, 3600).toDouble(),
      rewardSeconds: numv(
        config['rewardOfferSeconds'],
        60,
      ).clamp(60, 3600).toDouble(),
      rewardDuration: numv(
        config['rewardedAdFreeSeconds'],
        120,
      ).clamp(1, 3600).toDouble(),
    );
  }
  bool get testMode => flag(config['testMode'], true);
  bool get rewardReady =>
      _canRequest &&
      !_consentBusy &&
      _foreground &&
      clock.rewardEligible &&
      _rewarded != null;
  String get interstitialId => testMode
      ? 'ca-app-pub-3940256099942544/4411468910'
      : str(config['iosInterstitialId']);
  String get rewardedId => testMode
      ? 'ca-app-pub-3940256099942544/1712485313'
      : str(config['iosRewardedId']);
  String? get configurationError =>
      !testMode &&
          (str(config['iosAppId']).isEmpty ||
              interstitialId.isEmpty ||
              rewardedId.isEmpty)
      ? 'Production AdMob IDs are incomplete.'
      : null;
  void _update([String? message]) {
    if (_closed) return;
    if (message != null) status = message;
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_closed || _started || !Platform.isIOS) return;
    _started = true;
    if (configurationError != null) {
      _update(configurationError);
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _watch.start();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final now = _watch.elapsedMicroseconds / 1000000;
      clock.tick(now - _last, active: _foreground && !_consentBusy);
      _last = now;
      _update();
    });
    await _consent();
  }

  Future<void> _consent() async {
    if (_closed) return;
    _consentBusy = true;
    _update('Checking privacy choices…');
    final complete = Completer<void>();
    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(
          tagForUnderAgeOfConsent: flag(config['childDirected']),
        ),
        () {
          ConsentForm.loadAndShowConsentFormIfRequired((error) async {
            if (error != null) _update('Consent: ${error.message}');
            await _afterConsent();
            if (!complete.isCompleted) complete.complete();
          });
        },
        (error) async {
          _update('Consent update: ${error.message}');
          await _afterConsent();
          if (!complete.isCompleted) complete.complete();
        },
      );
    } catch (e) {
      _consentBusy = false;
      _update('Ads unavailable: $e');
      complete.complete();
    }
    return complete.future;
  }

  Future<void> _afterConsent() async {
    if (_closed) return;
    try {
      _canRequest = await ConsentInformation.instance.canRequestAds();
      privacyRequired =
          await ConsentInformation.instance
              .getPrivacyOptionsRequirementStatus() ==
          PrivacyOptionsRequirementStatus.required;
      if (_closed) return;
      _consentBusy = false;
      if (!_canRequest) {
        _update('Ads unavailable until consent requirements are met.');
        return;
      }
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(
          ageRestrictedTreatment: flag(config['childDirected'])
              ? AgeRestrictedTreatment.child
              : AgeRestrictedTreatment.unspecified,
          maxAdContentRating: MaxAdContentRating.g,
        ),
      );
      await MobileAds.instance.initialize();
      if (_closed) return;
      _iFailures = 0;
      _rFailures = 0;
      _loadInterstitial();
      _loadReward();
      _update(testMode ? 'Test ads enabled' : 'AdMob enabled');
    } catch (e) {
      _consentBusy = false;
      _update('Ads unavailable: $e');
    }
  }

  void _loadInterstitial() {
    if (_closed || !_canRequest || _interstitial != null) return;
    final generation = _generation;
    InterstitialAd.load(
      adUnitId: interstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          if (_closed || generation != _generation) {
            ad.dispose();
            return;
          }
          _interstitial = ad;
          _iFailures = 0;
          _update();
        },
        onAdFailedToLoad: (error) {
          if (_closed || generation != _generation) return;
          _update('Interstitial unavailable: ${error.code}');
          if (++_iFailures <= 5) {
            _iRetry?.cancel();
            _iRetry = Timer(
              Duration(seconds: math.min(60, 5 * (1 << (_iFailures - 1)))),
              _loadInterstitial,
            );
          }
        },
      ),
    );
  }

  void _loadReward() {
    if (_closed || !_canRequest || _rewarded != null) return;
    final generation = _generation;
    RewardedAd.load(
      adUnitId: rewardedId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          if (_closed || generation != _generation) {
            ad.dispose();
            return;
          }
          _rewarded = ad;
          _rFailures = 0;
          _update();
        },
        onAdFailedToLoad: (error) {
          if (_closed || generation != _generation) return;
          _update('Reward ad unavailable: ${error.code}');
          if (++_rFailures <= 5) {
            _rRetry?.cancel();
            _rRetry = Timer(
              Duration(seconds: math.min(60, 5 * (1 << (_rFailures - 1)))),
              _loadReward,
            );
          }
        },
      ),
    );
  }

  void naturalBreak() {
    if (_closed ||
        !_foreground ||
        _consentBusy ||
        !_canRequest ||
        !clock.interstitialEligible ||
        _interstitial == null) {
      return;
    }
    final ad = _interstitial!;
    _interstitial = null;
    clock.start();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        clock.finish();
        _loadInterstitial();
        _update();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        clock.finish();
        _loadInterstitial();
        _update('Interstitial could not show.');
      },
    );
    ad.show();
    _update();
  }

  bool showReward() {
    if (!rewardReady || _closed) return false;
    final ad = _rewarded!;
    _rewarded = null;
    var earned = false;
    clock.start();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        clock.finish();
        _loadReward();
        _update(
          earned
              ? 'Reward earned: 2 minutes without interstitials.'
              : 'Ad closed. No reward was earned.',
        );
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        clock.finish();
        _loadReward();
        _update('Reward ad could not show.');
      },
    );
    ad.show(
      onUserEarnedReward: (_, reward) {
        if (earned || _closed) return;
        earned = true;
        clock.earned();
        _update('Reward earned.');
      },
    );
    _update();
    return true;
  }

  Future<void> privacyOptions() async {
    if (!privacyRequired || clock.showing || _closed) return;
    _consentBusy = true;
    _generation++;
    _interstitial?.dispose();
    _interstitial = null;
    _rewarded?.dispose();
    _rewarded = null;
    _iRetry?.cancel();
    _rRetry?.cancel();
    _update();
    ConsentForm.showPrivacyOptionsForm((error) async {
      if (error != null) _update(error.message);
      await _afterConsent();
    });
  }

  Future<void> retry() async {
    if (!Platform.isIOS || _closed || _consentBusy || clock.showing) return;
    _generation++;
    _interstitial?.dispose();
    _interstitial = null;
    _rewarded?.dispose();
    _rewarded = null;
    _iRetry?.cancel();
    _rRetry?.cancel();
    await _consent();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _last = _watch.elapsedMicroseconds / 1000000;
  }

  @override
  void dispose() {
    _closed = true;
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _iRetry?.cancel();
    _rRetry?.cancel();
    _interstitial?.dispose();
    _rewarded?.dispose();
    _watch.stop();
    super.dispose();
  }
}
