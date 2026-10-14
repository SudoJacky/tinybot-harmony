import { webview } from '@kit.ArkWeb';
import { ShareInbox } from '../services/NativeActions';
import { LanguagePreferences } from '../services/LanguagePreferences';
import { AppearancePreferences } from '../services/AppearancePreferences';
import { McpOAuth } from '../services/McpOAuth';
import { LaunchActions } from '../services/LaunchActions';
/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;

  // Pages extend their backgrounds under the system bars, so match the status bar text to the theme.
  private applySystemBars(): void {
    if (!this.mainWindow) {
      return;
    }
    const dark = AppStorage.get<boolean>('tinybot.appearance.dark') === true;
    this.mainWindow.setWindowSystemBarProperties({ statusBarContentColor: dark ? '#FFFFFF' : '#000000' })
      .catch((err: Error) => hilog.error(DOMAIN, 'testTag', 'Failed to set bar color. Cause: %{public}s', err.message));
  }

  onConfigurationUpdate(config: Configuration): void {
    LanguagePreferences.refresh();
    AppearancePreferences.refresh(config);
    // The callback receives the new theme before context.config is refreshed.
    this.applySystemBars();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Prepare ArkWeb before mounting the first generated surface on the UI rendering path.
    const webStarted = Date.now();
    hilog.info(DOMAIN, 'TinybotWebUI', 'engine initialization start');
    webview.WebviewController.initializeWebEngine();
    hilog.info(DOMAIN, 'TinybotWebUI', 'engine initialized ms=%{public}d', Date.now() - webStarted);
    LanguagePreferences.initialize(this.context);
    AppearancePreferences.initialize(this.context);
    ShareInbox.receive(want, this.context.getApplicationContext().filesDir);
    LaunchActions.receive(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    McpOAuth.receive(want.uri || '');
    ShareInbox.receive(want, this.context.getApplicationContext().filesDir);
    LaunchActions.receive(want);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      this.mainWindow = windowStage.getMainWindowSync();
      AppearancePreferences.activate();
      this.applySystemBars();
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    AppStorage.setOrCreate('tinybot.foreground', true);
    LaunchActions.setForeground(true);
    LanguagePreferences.refresh();
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    AppStorage.setOrCreate('tinybot.foreground', false);
    LaunchActions.setForeground(false);
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
