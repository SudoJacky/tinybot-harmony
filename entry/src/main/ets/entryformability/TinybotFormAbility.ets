import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';

// Static launch shortcuts: no session data, credentials, network or refresh timers.
export default class TinybotFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const dimension = want.parameters?.[formInfo.FormParam.DIMENSION_KEY];
    return formBindingData.createFormBindingData({
      wide: dimension === formInfo.FormDimension.Dimension_2_4
    });
  }

  onAcquireFormState(_want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
