import type { Locale } from "./i18n";

const messages = {
  staging_unavailable: [
    "That setup task is no longer available. Check the counter for the next tray.",
    "その準備作業はできなくなりました。次のトレーをカウンターで確認してください。",
  ],
  location_refitting: [
    "This location is still being fitted out.",
    "この店舗は準備中です。",
  ],
  refit_unavailable: [
    "Refitting needs a closed stall, no active orders, a new cuisine, and enough cash for setup.",
    "改装には閉店済みの店舗、処理中の注文がないこと、新しい料理、十分な準備資金が必要です。",
  ],
  business_distressed: [
    "This venture is in distress. Pay the outstanding charges before resuming trade.",
    "経営危機のため営業できません。未払い金を支払ってください。",
  ],
  business_dormant: [
    "Lease a location before ordering stock.",
    "在庫を仕入れるには店舗の契約が必要です。",
  ],
  stall_limit: [
    "This business has reached its location limit.",
    "店舗数の上限に達しています。",
  ],
  location_not_releasable: [
    "Close this stall and let its accepted orders settle before surrendering it.",
    "店舗を閉め、受付済みの注文が終了してから返却してください。",
  ],
  arrears_unpayable: [
    "There isn’t enough cash to pay all outstanding charges.",
    "未払い金を全額支払うための現金が足りません。",
  ],
  salvage_unavailable: [
    "This asset is no longer available to sell.",
    "この資産は売却できなくなりました。",
  ],
  business_not_distressed: [
    "Bankruptcy can only be accepted during a recovery window.",
    "破産を選択できるのは再建期間中だけです。",
  ],

  allowance_already_claimed: [
    "You’ve already claimed your dining allowance for this game day.",
    "このゲーム日分の食事手当はすでに受け取っています。",
  ],
  visitor_fund_exhausted: [
    "The hall has run out of funds for dining allowances.",
    "ホールの食事手当の予算がなくなりました。",
  ],
  insufficient_funds: [
    "Your dining balance is too low for this order.",
    "この注文には食事用残高が足りません。",
  ],
  over_budget: [
    "This order costs more than the available dining budget.",
    "この注文は利用できる食事予算を超えています。",
  ],
  visit_already_active: [
    "You already have an active visit. Finish it before starting another.",
    "来店中です。次の来店を始めるには、現在の来店を終えてください。",
  ],
  unknown_visit: [
    "This visit is no longer active.",
    "この来店はすでに終了しています。",
  ],
  unknown_tray: [
    "This order is no longer active.",
    "この注文はすでに終了しています。",
  ],
  tray_settled: [
    "This order has already been settled.",
    "この注文はすでに精算済みです。",
  ],
  preparation_started: [
    "The kitchen has started preparing this order, so it can no longer be canceled.",
    "調理が始まったため、この注文はキャンセルできません。",
  ],
  no_dessert: [
    "This stall has no dessert for this menu.",
    "この店舗のメニューにはデザートがありません。",
  ],
  no_dessert_offer: [
    "There’s no dessert offer for this visit now.",
    "この来店では現在デザートを注文できません。",
  ],
  dessert_offer_expired: [
    "The time to order dessert has expired.",
    "デザートの注文期限が過ぎました。",
  ],
  hall_cleaning: [
    "The hall is closed for cleaning. Service resumes at 05:00 game time.",
    "ホールは清掃中です。ゲーム内時刻の05:00に営業を再開します。",
  ],
  stall_not_accepting_orders: [
    "This stall is closed to new orders.",
    "この店舗は現在、新規注文を受け付けていません。",
  ],
  queue_full: [
    "This stall’s order queue is full. Wait for a spot or try another stall.",
    "この店舗の注文待ち枠がいっぱいです。空きを待つか、別の店舗をお試しください。",
  ],
  cannot_finish_before_cleaning: [
    "The kitchen can’t finish this order before hall cleaning starts at 03:00 game time.",
    "ゲーム内時刻の03:00に清掃が始まるまでに、この注文を提供できません。",
  ],
  cannot_finish_before_deadline: [
    "The kitchen can’t finish this order within the service window.",
    "この注文は提供期限内に仕上げられません。",
  ],
  ingredients_unavailable: [
    "The stall doesn’t have enough of the ingredients allowed for this order.",
    "この注文に使用できる食材の在庫が足りません。",
  ],
  excluded_ingredient: [
    "An ingredient in this order doesn’t meet your selected dietary requirements.",
    "この注文には、選択した食事条件に合わない食材が含まれています。",
  ],
  carbohydrate_limit: [
    "This order would exceed the carbohydrate limit for your visit.",
    "この注文は、今回の来店で設定された炭水化物の上限を超えます。",
  ],
  missing_metadata: [
    "The stall lacks enough ingredient information to verify your dietary requirements.",
    "食材情報が不足しているため、選択した食事条件を満たすか確認できません。",
  ],
  profile_not_enabled: [
    "This dietary profile is unavailable in this hall.",
    "このホールでは、この食事条件を利用できません。",
  ],
  unknown_profile: [
    "That dietary profile isn’t available. Choose a profile from the list.",
    "指定した食事条件は利用できません。一覧から選択してください。",
  ],
  confirmation_required: [
    "Review the order terms before confirming.",
    "注文を確定する前に、内容を確認してください。",
  ],
  stale_terms: [
    "The order terms changed. Review the order again before confirming.",
    "注文条件が変わりました。内容を再確認してから確定してください。",
  ],
  slot_unavailable: [
    "This stall can’t be reserved or leased right now. Check your current reservation or choose another stall.",
    "現在この区画を予約・契約できません。予約状況を確認するか、別の区画を選んでください。",
  ],
  stall_taken: [
    "Another restaurant already occupies this stall.",
    "この区画はすでに別のレストランが使用しています。",
  ],
  unknown_slot: [
    "This stall location is unavailable.",
    "この区画は利用できません。",
  ],
  unknown_stall: [
    "This stall is no longer available.",
    "この店舗は現在利用できません。",
  ],
  no_draft: [
    "You have no active stall reservation to release.",
    "解除できる区画の予約がありません。",
  ],
  venture_already_active: [
    "Your profile already owns an active restaurant.",
    "このプロフィールはすでに営業中のレストランを所有しています。",
  ],
  unknown_cuisine: [
    "That cuisine is unavailable. Choose one from the list.",
    "その料理ジャンルは利用できません。一覧から選択してください。",
  ],
  waitlist_unavailable: [
    "Your current restaurant, reservation, or waitlist status doesn’t allow this change.",
    "レストラン、予約、または空き待ちの現在の状況では、この変更はできません。",
  ],
  staff_off_duty: [
    "The stall is missing on-duty staff for preparation, finishing, or counter service.",
    "仕込み、仕上げ、またはカウンター業務の担当者が勤務中ではありません。",
  ],
  unpaid_rent: [
    "The stall has unpaid rent. It can’t serve customers until the rent is paid.",
    "賃料が未払いです。支払いが済むまで接客できません。",
  ],
  owner_absent: [
    "The owner isn’t marked present and the stall isn’t authorized for unattended service.",
    "オーナーが在席しておらず、不在時の営業も許可されていません。",
  ],
  hire_unavailable: [
    "Hiring requires an available roster spot, a valid role and schedule, and enough available cash.",
    "雇用には、名簿の空き、有効な役割と勤務時間、十分な手元資金が必要です。",
  ],
  invalid_schedule: [
    "The schedule couldn’t be saved. Check that the worker is still on staff and the shift is 1–12 game hours long.",
    "勤務時間を保存できませんでした。スタッフが在籍中で、勤務時間がゲーム内で1～12時間か確認してください。",
  ],
  worker_unavailable: [
    "That worker is no longer available on this stall’s roster.",
    "そのスタッフは現在、この店舗の名簿にいません。",
  ],
  stale_shift_offer: [
    "The helper shift terms changed. Review the latest offer before accepting.",
    "補助勤務の条件が変わりました。最新の募集内容を確認してください。",
  ],
  shift_unavailable: [
    "This helper shift is no longer available to you.",
    "この補助勤務は現在利用できません。",
  ],
  unfunded_shift: [
    "This stall can’t reserve the wages for this helper shift.",
    "この店舗は、補助勤務に必要な賃金を確保できません。",
  ],
  selection_unavailable: [
    "That handover is no longer available. Check the current task.",
    "その受け渡しは現在選べません。現在の作業を確認してください。",
  ],
  insufficient_cash: [
    "The restaurant doesn’t have enough available cash for this action.",
    "この操作に必要なレストランの手元資金が足りません。",
  ],
  unknown_restaurant: [
    "This restaurant is unavailable.",
    "このレストランは利用できません。",
  ],
  unknown_recipe: [
    "This recipe is unavailable.",
    "このレシピは利用できません。",
  ],
  wrong_cuisine: [
    "This recipe belongs to a different cuisine.",
    "このレシピは別の料理ジャンルのものです。",
  ],
  already_unlocked: [
    "This recipe is already unlocked.",
    "このレシピはすでに解放済みです。",
  ],
  recipe_locked: [
    "This recipe is still locked.",
    "このレシピはまだ解放されていません。",
  ],
  not_on_menu: [
    "This item is no longer on the stall’s menu.",
    "この品は現在、店舗のメニューにありません。",
  ],
  wrong_course_kind: [
    "This item can’t be ordered as the selected course.",
    "この品は選択したコースとして注文できません。",
  ],
  invalid_price: [
    "The menu price is outside the allowed range.",
    "メニュー価格が許容範囲外です。",
  ],
  invalid_money: [
    "Enter a valid nonnegative amount in cents.",
    "0以上の有効な金額をセント単位で入力してください。",
  ],
  unknown_product: [
    "This product is unavailable at the wholesale market.",
    "この商品は卸売市場で利用できません。",
  ],
  invalid_quantity: [
    "The purchase quantity must be a positive whole number within the allowed range.",
    "購入数量は、許容範囲内の正の整数で入力してください。",
  ],
  invalid_price_limit: [
    "The maximum purchase price is outside the allowed range.",
    "購入価格の上限が許容範囲外です。",
  ],
  no_pending_request: [
    "There’s no pending purchase request for this product to cancel.",
    "この商品には、取り消せる購入依頼がありません。",
  ],
  unknown_line: [
    "That ingredient is no longer part of the recipe.",
    "その食材は現在、このレシピに含まれていません。",
  ],
  invalid_policy: [
    "That substitution option is unavailable for this ingredient.",
    "その代替設定はこの食材には使用できません。",
  ],
  no_approved_substitute: [
    "This ingredient has no approved substitute.",
    "この食材には使用できる代替品がありません。",
  ],
  starter_stock_unavailable: [
    "There’s no starter stock left to request within your budget and available cash.",
    "予算と手元資金の範囲内で注文できる初期食材がありません。",
  ],
  invalid_restock_policy: [
    "The restock policy couldn’t be saved. Check the product, target stock, maximum price, and budget.",
    "補充設定を保存できませんでした。商品、目標在庫、上限価格、予算を確認してください。",
  ],
  invalid_pricing_policy: [
    "The pricing policy couldn’t be saved. Choose an unlocked recipe and check the price limits and markup.",
    "価格設定を保存できませんでした。解放済みのレシピを選び、価格の上下限と上乗せ率を確認してください。",
  ],
  invitation_unavailable: [
    "This invitation is invalid, expired, already used, or revoked.",
    "この招待は無効、期限切れ、使用済み、または取り消し済みです。",
  ],
  no_invitation_quota: [
    "You don’t have any invitations available to issue.",
    "発行できる招待がありません。",
  ],
  already_owner: [
    "Your profile already has an owner license.",
    "このプロフィールにはすでに営業許可があります。",
  ],
  owner_required: [
    "You need an owner license to perform this action.",
    "この操作には営業許可が必要です。",
  ],
  application_unavailable: [
    "Your license application status or eligibility doesn’t allow this action.",
    "現在の申請状況または申請資格では、この操作はできません。",
  ],
  review_unavailable: [
    "The application is no longer eligible for this decision, or the decision reason is missing or invalid.",
    "現在この申請にはその判断を下せないか、判断理由が未入力または無効です。",
  ],
  invalid_profile: [
    "The profile details were invalid. Enter a display name between 1 and 40 characters.",
    "プロフィールの内容が無効です。表示名を1～40文字で入力してください。",
  ],
  device_already_bound: [
    "This browser already has a Feud Hall profile.",
    "このブラウザーにはすでにFeud Hallのプロフィールがあります。",
  ],
  recovery_unavailable: [
    "This recovery code is invalid, expired, or already used, or this browser already has a profile.",
    "復旧コードが無効、期限切れ、使用済み、またはこのブラウザーにすでにプロフィールがあります。",
  ],
  unauthenticated: [
    "This browser needs an active Feud Hall profile for that action.",
    "この操作には、このブラウザーで利用できるFeud Hallのプロフィールが必要です。",
  ],
  revoked_device: [
    "This browser’s access to the profile was revoked.",
    "このブラウザーからプロフィールへのアクセスは無効になっています。",
  ],
  forbidden: [
    "Your profile doesn’t have permission to perform this action.",
    "このプロフィールには、この操作を行う権限がありません。",
  ],
  device_denied: [
    "The hall blocked device setup. Open Feud Hall at its usual address and wait a moment before trying again.",
    "端末の登録がブロックされました。通常のアドレスからFeud Hallを開き、少し待ってからお試しください。",
  ],
  command_denied: [
    "The hall blocked this request. Open Feud Hall at its usual address and wait a moment before trying again.",
    "リクエストがブロックされました。通常のアドレスからFeud Hallを開き、少し待ってからお試しください。",
  ],
  invalid_command: [
    "The server rejected the request details. Check the fields you entered.",
    "リクエストの内容が無効です。入力欄を確認してください。",
  ],
  invalid_payload: [
    "The server rejected the values supplied for this action.",
    "この操作で送信した値が無効です。",
  ],
  invalid_quote: [
    "The server couldn’t read the order details. Check the stall and menu selections.",
    "注文内容を読み取れませんでした。店舗とメニューの選択を確認してください。",
  ],
  command_id_conflict: [
    "The server already recorded a different request under this action’s ID.",
    "この操作のIDには、すでに別のリクエストが記録されています。",
  ],
  hall_not_initialized: [
    "The hall hasn’t finished starting. Try again when it opens.",
    "ホールはまだ起動中です。営業開始後にもう一度お試しください。",
  ],
  management_unavailable: [
    "Restaurant management is unavailable in this hall.",
    "このホールではレストランの経営機能を利用できません。",
  ],
  recovery_required: [
    "The hall needs to recover before it can accept this action.",
    "この操作を受け付けるには、ホールの復旧が必要です。",
  ],
  unavailable: [
    "The hall couldn’t answer this request right now. Try again in a moment.",
    "現在このリクエストに応答できません。少し待ってからお試しください。",
  ],
  unknown_outcome: [
    "The hall didn’t answer this request in time. Try again in a moment.",
    "ホールから時間内に応答がありませんでした。少し待ってからお試しください。",
  ],
  network_error: [
    "Couldn’t reach the hall. Check your connection and try again.",
    "ホールに接続できませんでした。接続を確認してからもう一度お試しください。",
  ],
  native_storage_unavailable: [
    "The desktop app couldn’t save your device credential. Unlock your system credential store and try again.",
    "デバイスの認証情報を保存できませんでした。システムの認証情報ストアのロックを解除して、もう一度お試しください。",
  ],
  native_connection_unavailable: [
    "The desktop app couldn’t reach the hall.",
    "デスクトップアプリからホールに接続できませんでした。",
  ],
  unknown_rejection: [
    "The hall refused this action without a recognized reason.",
    "操作を受け付けられませんでした。理由は確認できません。",
  ],
} satisfies Record<string, readonly [string, string]>;

export function refusalMessage(locale: Locale, code: string) {
  const message = Object.hasOwn(messages, code)
    ? messages[code as keyof typeof messages]
    : messages.unknown_rejection;
  return message[locale === "ja" ? 1 : 0];
}
