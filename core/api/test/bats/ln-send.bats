#!/usr/bin/env bats

load "helpers/setup-and-teardown"
load "helpers/ln"

setup_file() {
  clear_cache

  bitcoind_init
  start_trigger
  start_server
  start_exporter

  lnds_init
  initialize_user_from_onchain "$ALICE_TOKEN_NAME" "$ALICE_PHONE" "$CODE"
  user_update_username "$ALICE_TOKEN_NAME"
  initialize_user_from_onchain "$BOB_TOKEN_NAME" "$BOB_PHONE" "$CODE"
}

teardown_file() {
  stop_trigger
  stop_server
  stop_exporter
}

setup() {
  reset_redis
}

teardown() {
  if [[ "$(balance_for_check)" != 0 ]]; then
    fail "Error: balance_for_check failed"
  fi
}

amount_sent_for_ln_txn_by_hash() {
  token_name="$1"
  payment_hash="$2"

  first=20
  txn_variables=$(
  jq -n \
  --argjson first "$first" \
  '{"first": $first}'
  )
  exec_graphql "$token_name" 'transactions' "$txn_variables" > /dev/null

  jq_query='
    [
      .data.me.defaultAccount.transactions.edges[]
      | select(.node.initiationVia.paymentHash == $payment_hash)
      | select(.node.direction == "SEND")
    ]
      | first .node.settlementAmount
  '
  local amount=$(echo $output \
    | jq -r \
      --arg payment_hash "$payment_hash" \
      "$jq_query"
  )
  abs $amount
}

btc_amount=1000
usd_amount=50

@test "ln-send: lightning settled - lnInvoicePaymentSend from btc" {
  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice --amt $btc_amount)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )

  exec_graphql "$token_name" 'ln-invoice-fee-probe' "$variables"
  fee_amount="$(graphql_output '.data.lnInvoiceFeeProbe.amount')"
  [[ "${fee_amount}" = "0" ]] || exit 1

  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "$btc_amount" ]] || exit 1
}

@test "ln-send: lightning settled - lnInvoicePaymentSend from btc, no fee probe" {
  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice --amt $btc_amount)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )

  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "$btc_amount" ]] || exit 1
}

@test "ln-send: lightning settled - lnInvoicePaymentSend from usd" {
  token_name="$ALICE_TOKEN_NAME"
  usd_wallet_name="$token_name.usd_wallet_id"

  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice --amt $btc_amount)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )

  exec_graphql "$token_name" 'ln-usd-invoice-fee-probe' "$variables"
  fee_amount="$(graphql_output '.data.lnUsdInvoiceFeeProbe.amount')"
  [[ "${fee_amount}" = "0" ]] || exit 1

  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "$btc_amount" ]] || exit 1
}

@test "ln-send: lightning settled - lnInvoicePaymentSend from usd, no fee probe" {
  token_name="$ALICE_TOKEN_NAME"
  usd_wallet_name="$token_name.usd_wallet_id"

  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice --amt $btc_amount)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )

  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "$btc_amount" ]] || exit 1
}

@test "ln-send: lightning settled - lnNoAmountInvoicePaymentSend" {
  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    --arg amount $btc_amount \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request, amount: $amount}}'
  )

  exec_graphql "$token_name" 'ln-no-amount-invoice-fee-probe' "$variables"
  fee_amount="$(graphql_output '.data.lnNoAmountInvoiceFeeProbe.amount')"
  [[ "${fee_amount}" = "0" ]] || exit 1

  exec_graphql "$token_name" 'ln-no-amount-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnNoAmountInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "$btc_amount" ]] || exit 1
}

@test "ln-send: lightning settled - lnNoAmountInvoicePaymentSend, no fee probe" {
  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    --arg amount $btc_amount \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request, amount: $amount}}'
  )

  exec_graphql "$token_name" 'ln-no-amount-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnNoAmountInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "$btc_amount" ]] || exit 1
}

@test "ln-send: lightning settled - lnNoAmountUsdInvoicePaymentSend" {
  token_name="$ALICE_TOKEN_NAME"
  usd_wallet_name="$token_name.usd_wallet_id"

  initial_balance="$(balance_for_wallet $token_name 'USD')"
  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_wallet_name)" \
    --arg payment_request "$payment_request" \
    --arg amount $usd_amount \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request, amount: $amount}}'
  )

  exec_graphql "$token_name" 'ln-no-amount-usd-invoice-fee-probe' "$variables"
  fee_amount="$(graphql_output '.data.lnNoAmountUsdInvoiceFeeProbe.amount')"
  [[ "${fee_amount}" = "0" ]] || exit 1

  exec_graphql "$token_name" 'ln-no-amount-usd-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnNoAmountUsdInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_balance="$(balance_for_wallet $token_name 'USD')"
  wallet_diff="$(( $initial_balance - $final_balance ))"
  [[ "$wallet_diff" == "$usd_amount" ]] || exit 1

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" -gt "0" ]] || exit 1
}

@test "ln-send: lightning settled - lnNoAmountUsdInvoicePaymentSend, no fee probe" {
  token_name="$ALICE_TOKEN_NAME"
  usd_wallet_name="$token_name.usd_wallet_id"

  initial_balance="$(balance_for_wallet $token_name 'USD')"
  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  invoice_response="$(lnd_outside_cli addinvoice)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_wallet_name)" \
    --arg payment_request "$payment_request" \
    --arg amount $usd_amount \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request, amount: $amount}}'
  )

  exec_graphql "$token_name" 'ln-no-amount-usd-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnNoAmountUsdInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"

  final_balance="$(balance_for_wallet $token_name 'USD')"
  wallet_diff="$(( $initial_balance - $final_balance ))"
  [[ "$wallet_diff" == "$usd_amount" ]] || exit 1

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" -gt "0" ]] || exit 1
}

@test "ln-send: intraledger settled - lnInvoicePaymentSend from btc to btc, with contacts check" {
  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  recipient_token_name="user_$RANDOM"
  recipient_phone="$(random_phone)"
  login_user \
    "$recipient_token_name" \
    "$recipient_phone"  \
    "$CODE"
  user_update_username "$recipient_token_name"
  btc_recipient_wallet_name="$recipient_token_name.btc_wallet_id"

  initial_balance="$(balance_for_wallet $token_name 'BTC')"
  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  # Check is not contact before send
  run is_contact "$token_name" "$recipient_token_name"
  [[ "$status" -ne "0" ]] || exit 1
  run is_contact "$recipient_token_name" "$token_name"
  [[ "$status" -ne "0" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_recipient_wallet_name)" \
    --arg amount "$btc_amount" \
    '{input: {walletId: $wallet_id, amount: $amount}}'
  )
  exec_graphql "$recipient_token_name" 'ln-invoice-create' "$variables"
  invoice="$(graphql_output '.data.lnInvoiceCreate.invoice')"

  payment_request="$(echo $invoice | jq -r '.paymentRequest')"
  [[ "${payment_request}" != "null" ]] || exit 1
  payment_hash="$(echo $invoice | jq -r '.paymentHash')"
  [[ "${payment_hash}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )

  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"
  check_for_ln_initiated_settled "$recipient_token_name" "$payment_hash"

  final_balance="$(balance_for_wallet $token_name 'BTC')"
  wallet_diff="$(( $initial_balance - $final_balance ))"
  [[ "$wallet_diff" == "$btc_amount" ]] || exit 1

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "0" ]] || exit 1

  # Check is contact after send
  run is_contact "$token_name" "$recipient_token_name"
  [[ "$status" == "0" ]] || exit 1
  run is_contact "$recipient_token_name" "$token_name"
  [[ "$status" == "0" ]] || exit 1
}

@test "ln-send: intraledger settled - lnInvoicePaymentSend from usd to btc" {
  token_name="$ALICE_TOKEN_NAME"
  usd_wallet_name="$token_name.usd_wallet_id"

  recipient_token_name="$BOB_TOKEN_NAME"
  btc_recipient_wallet_name="$recipient_token_name.btc_wallet_id"

  initial_recipient_balance="$(balance_for_wallet $recipient_token_name 'BTC')"
  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_recipient_wallet_name)" \
    --arg amount "$btc_amount" \
    '{input: {walletId: $wallet_id, amount: $amount}}'
  )
  exec_graphql "$recipient_token_name" 'ln-invoice-create' "$variables"
  invoice="$(graphql_output '.data.lnInvoiceCreate.invoice')"

  payment_request="$(echo $invoice | jq -r '.paymentRequest')"
  [[ "${payment_request}" != "null" ]] || exit 1
  payment_hash="$(echo $invoice | jq -r '.paymentHash')"
  [[ "${payment_hash}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )

  exec_graphql "$token_name" 'ln-usd-invoice-fee-probe' "$variables"
  fee_amount="$(graphql_output '.data.lnUsdInvoiceFeeProbe.amount')"
  [[ "${fee_amount}" = "0" ]] || exit 1

  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"
  check_for_ln_initiated_settled "$recipient_token_name" "$payment_hash"

  final_recipient_balance="$(balance_for_wallet $recipient_token_name 'BTC')"
  recipient_wallet_diff="$(( $final_recipient_balance - $initial_recipient_balance ))"
  [[ "$recipient_wallet_diff" == "$btc_amount" ]] || exit 1

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "0" ]] || exit 1
}

@test "ln-send: intraledger settled - lnNoAmountInvoicePaymentSend from btc to usd" {
  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  recipient_token_name="$BOB_TOKEN_NAME"
  usd_recipient_wallet_name="$recipient_token_name.usd_wallet_id"

  initial_balance="$(balance_for_wallet $token_name 'BTC')"
  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_recipient_wallet_name)" \
    '{input: {walletId: $wallet_id}}'
  )
  exec_graphql "$recipient_token_name" 'ln-no-amount-invoice-create' "$variables"
  invoice="$(graphql_output '.data.lnNoAmountInvoiceCreate.invoice')"

  payment_request="$(echo $invoice | jq -r '.paymentRequest')"
  [[ "${payment_request}" != "null" ]] || exit 1
  payment_hash="$(echo $invoice | jq -r '.paymentHash')"
  [[ "${payment_hash}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    --arg amount $btc_amount \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request, amount: $amount}}'
  )

  exec_graphql "$token_name" 'ln-no-amount-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnNoAmountInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"
  check_for_ln_initiated_settled "$recipient_token_name" "$payment_hash"

  final_balance="$(balance_for_wallet $token_name 'BTC')"
  wallet_diff="$(( $initial_balance - $final_balance ))"
  [[ "$wallet_diff" == "$btc_amount" ]] || exit 1

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "0" ]] || exit 1
}

@test "ln-send: intraledger settled - lnNoAmountUsdInvoicePaymentSend from usd to usd" {
  token_name="$ALICE_TOKEN_NAME"
  usd_wallet_name="$token_name.usd_wallet_id"

  recipient_token_name="$BOB_TOKEN_NAME"
  usd_recipient_wallet_name="$recipient_token_name.usd_wallet_id"

  initial_balance="$(balance_for_wallet $token_name 'USD')"
  initial_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_recipient_wallet_name)" \
    '{input: {walletId: $wallet_id}}'
  )
  exec_graphql "$recipient_token_name" 'ln-no-amount-invoice-create' "$variables"
  invoice="$(graphql_output '.data.lnNoAmountInvoiceCreate.invoice')"

  payment_request="$(echo $invoice | jq -r '.paymentRequest')"
  [[ "${payment_request}" != "null" ]] || exit 1
  payment_hash="$(echo $invoice | jq -r '.paymentHash')"
  [[ "${payment_hash}" != "null" ]] || exit 1

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_wallet_name)" \
    --arg payment_request "$payment_request" \
    --arg amount $usd_amount \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request, amount: $amount}}'
  )

  exec_graphql "$token_name" 'ln-no-amount-usd-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnNoAmountUsdInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  # Check for settled
  retry 15 1 check_for_ln_initiated_settled "$token_name" "$payment_hash"
  check_for_ln_initiated_settled "$recipient_token_name" "$payment_hash"

  final_balance="$(balance_for_wallet $token_name 'USD')"
  wallet_diff="$(( $initial_balance - $final_balance ))"
  [[ "$wallet_diff" == "$usd_amount" ]] || exit 1

  final_lnd1_balance=$(lnd_cli channelbalance | jq -r '.balance')
  lnd1_diff="$(( $initial_lnd1_balance - $final_lnd1_balance ))"
  [[ "$lnd1_diff" == "0" ]] || exit 1
}

@test "ln-send: ln settled - settle failed and then successful payment" {
  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  threshold_amount=150000
  invoice_response="$(lnd_outside_2_cli addinvoice --amt $threshold_amount)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  payment_hash=$(echo $invoice_response | jq -r '.r_hash')
  [[ "${payment_request}" != "null" ]] || exit 1

  check_num_txns() {
    expected_num="$1"

    num_txns="$(num_txns_for_hash "$token_name" "$payment_hash")"
    [[ "$num_txns" == "$expected_num" ]] || exit 1
  }

  # Rebalance last hop so payment will fail
  rebalance_channel lnd_outside_cli lnd_outside_2_cli "$(( $threshold_amount - 1 ))"

  # Try payment and check for fail
  initial_balance="$(balance_for_wallet $token_name 'BTC')"

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )
  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  error_msg="$(graphql_output '.data.lnInvoicePaymentSend.errors[0].message')"
  [[ "${send_status}" = "FAILURE" ]] || exit 1
  [[ "${error_msg}" == "Unable to find a route for payment." ]] || exit 1

  # Check for txns
  retry 15 1 check_num_txns "2"
  balance_after_fail="$(balance_for_wallet $token_name 'BTC')"
  [[ "$initial_balance" == "$balance_after_fail" ]] || exit 1

  # Rebalance last hop so same payment will succeed
  rebalance_channel lnd_outside_cli lnd_outside_2_cli "$(( $threshold_amount * 2 ))"
  lnd_cli resetmc

  # Retry payment and check for success
  exec_graphql "$token_name" 'ln-invoice-fee-probe' "$variables"
  num_errors="$(graphql_output '.data.lnInvoiceFeeProbe.errors | length')"
  fee_amount="$(graphql_output '.data.lnInvoiceFeeProbe.amount')"
  [[ "$num_errors" == "0" ]] || exit 1
  [[ "${fee_amount}" -gt "0" ]] || exit 1

  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "SUCCESS" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for txns
  retry 15 1 check_num_txns "3"
  balance_after_success="$(balance_for_wallet $token_name 'BTC')"
  [[ "$balance_after_success" -lt "$initial_balance" ]] || exit 1
}

@test "ln-send: ln settled - settle failed and then pending-to-failed payment" {
  skip "missing xxd dep, failing on concourse"

  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"

  threshold_amount=150000
  secret=$(xxd -l 32 -p /dev/urandom)
  payment_hash=$(echo -n $secret | xxd -r -p | sha256sum | cut -d ' ' -f1)
  invoice_response="$(lnd_outside_2_cli addholdinvoice $payment_hash --amt $threshold_amount)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  [[ "${payment_request}" != "null" ]] || exit 1

  check_num_txns() {
    expected_num="$1"

    num_txns="$(num_txns_for_hash "$token_name" "$payment_hash")"
    [[ "$num_txns" == "$expected_num" ]] || exit 1
  }

  # Rebalance last hop so payment will fail
  rebalance_channel lnd_outside_cli lnd_outside_2_cli "$(( $threshold_amount - 1 ))"

  # Try payment and check for fail
  initial_balance="$(balance_for_wallet $token_name 'BTC')"

  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $btc_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )
  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  error_msg="$(graphql_output '.data.lnInvoicePaymentSend.errors[0].message')"
  [[ "${send_status}" = "FAILURE" ]] || exit 1
  [[ "${error_msg}" == "Unable to find a route for payment." ]] || exit 1

  # Check for txns
  retry 15 1 check_num_txns "2"
  balance_after_fail="$(balance_for_wallet $token_name 'BTC')"
  [[ "$initial_balance" == "$balance_after_fail" ]] || exit 1

  # Rebalance last hop so same payment will succeed
  rebalance_channel lnd_outside_cli lnd_outside_2_cli "$(( $threshold_amount * 2 ))"
  lnd_cli resetmc

  # Retry payment and check for pending
  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "PENDING" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for txns
  retry 15 1 check_num_txns "3"
  check_for_ln_initiated_pending "$token_name" "$payment_hash" "10" \
    || exit 1
  balance_while_pending="$(balance_for_wallet $token_name 'BTC')"
  [[ "$balance_while_pending" -lt "$initial_balance" ]] || exit 1

  # Cancel hodl invoice
  lnd_outside_2_cli cancelinvoice "$payment_hash"

  retry 15 1 check_num_txns "4"
  balance_after_pending_failed="$(balance_for_wallet $token_name 'BTC')"
  [[ "$balance_after_pending_failed" == "$initial_balance" ]] || exit 1

  run check_for_ln_initiated_pending "$token_name" "$payment_hash" "10"
  [[ "$status" -ne 0 ]] || exit 1
}

@test "ln-send: ln settled - pending-to-failed usd payment" {
  skip "missing xxd dep, failing on concourse"

  token_name="$ALICE_TOKEN_NAME"
  btc_wallet_name="$token_name.btc_wallet_id"
  usd_wallet_name="$token_name.usd_wallet_id"

  threshold_amount=150000
  secret=$(xxd -l 32 -p /dev/urandom)
  payment_hash=$(echo -n $secret | xxd -r -p | sha256sum | cut -d ' ' -f1)
  invoice_response="$(lnd_outside_2_cli addholdinvoice $payment_hash --amt $threshold_amount)"
  payment_request="$(echo $invoice_response | jq -r '.payment_request')"
  [[ "${payment_request}" != "null" ]] || exit 1

  check_num_txns() {
    expected_num="$1"

    num_txns="$(num_txns_for_hash "$token_name" "$payment_hash")"
    [[ "$num_txns" == "$expected_num" ]] || exit 1
  }

  initial_btc_balance="$(balance_for_wallet $token_name 'BTC')"
  initial_usd_balance="$(balance_for_wallet $token_name 'USD')"

  # Rebalance last hop so payment will succeed
  rebalance_channel lnd_outside_cli lnd_outside_2_cli "$(( $threshold_amount * 2 ))"
  lnd_cli resetmc

  # Try payment and check for pending
  variables=$(
    jq -n \
    --arg wallet_id "$(read_value $usd_wallet_name)" \
    --arg payment_request "$payment_request" \
    '{input: {walletId: $wallet_id, paymentRequest: $payment_request}}'
  )
  exec_graphql "$token_name" 'ln-invoice-payment-send' "$variables"
  send_status="$(graphql_output '.data.lnInvoicePaymentSend.status')"
  [[ "${send_status}" = "PENDING" ]] || exit 1

  transaction_payment_hash="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentHash')"
  [[ "${transaction_payment_hash}" == "${payment_hash}" ]] || exit 1

  transaction_payment_request="$(graphql_output '.data.lnInvoicePaymentSend.transaction.initiationVia.paymentRequest')"
  [[ "${transaction_payment_request}" == "${payment_request}" ]] || exit 1

  # Check for txns
  retry 15 1 check_num_txns "1"
  check_for_ln_initiated_pending "$token_name" "$payment_hash" "10" \
    || exit 1
  btc_balance_while_pending="$(balance_for_wallet $token_name 'BTC')"
  usd_balance_while_pending="$(balance_for_wallet $token_name 'USD')"
  [[ "$btc_balance_while_pending" == "$initial_btc_balance" ]] || exit 1
  [[ "$usd_balance_while_pending" -lt "$initial_usd_balance" ]] || exit 1

  # Cancel hodl invoice
  lnd_outside_2_cli cancelinvoice "$payment_hash"

  retry 15 1 check_num_txns "2"
  btc_balance_after_pending_failed="$(balance_for_wallet $token_name 'BTC')"
  usd_balance_after_pending_failed="$(balance_for_wallet $token_name 'USD')"
  [[ "$btc_balance_after_pending_failed" -gt "$btc_balance_while_pending" ]] || exit 1
  [[ "$usd_balance_after_pending_failed" == "$usd_balance_while_pending" ]] || exit 1

  run check_for_ln_initiated_pending "$token_name" "$payment_hash" "10"
  [[ "$status" -ne 0 ]] || exit 1
}
