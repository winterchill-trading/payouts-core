open! Core

module Stable = struct
  module V1 = struct
    type t =
      { quote_ref : string
      ; sell : Money.Amount.Stable.V1.t
      ; buy : Money.Amount.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

module Hook = struct
  type conversion = t

  type t =
    { quote : sell:Money.Currency.t -> buy:Money.Amount.t -> (conversion, string) Result.t
    }

  let none = { quote = (fun ~sell:_ ~buy:_ -> Error "no conversion configured") }

  let fixed_rates rates =
    let quote ~sell ~buy =
      let buy_currency = Money.Amount.currency buy in
      match
        List.find rates ~f:(fun (s, b, _) ->
          Money.Currency.equal s sell && Money.Currency.equal b buy_currency)
      with
      | None ->
        Error
          (sprintf
             "no rate from %s to %s"
             (Money.Currency.to_string sell)
             (Money.Currency.to_string buy_currency))
      | Some (_, _, rate) when Q.leq rate Q.zero -> Error "rate is not positive"
      | Some (_, _, rate) ->
        let sold =
          Money.Amount.of_q ~rounding:Up sell (Q.div (Money.Amount.to_q buy) rate)
        in
        Ok
          { quote_ref =
              sprintf
                "fixed:%s:%s"
                (Money.Currency.to_string sell)
                (Money.Currency.to_string buy_currency)
          ; sell = sold
          ; buy
          }
    in
    { quote }
  ;;
end

let validate t ~sell ~buy =
  if Money.Currency.equal sell (Money.Amount.currency buy)
  then Or_error.error_s [%message "conversion into the same currency"]
  else if not (Money.Amount.equal t.buy buy)
  then
    Or_error.error_s
      [%message
        "conversion buys another amount"
          ~expected:(buy : Money.Amount.t)
          ~got:(t.buy : Money.Amount.t)]
  else if not (Money.Currency.equal (Money.Amount.currency t.sell) sell)
  then
    Or_error.error_s
      [%message
        "conversion sells another currency"
          ~expected:(sell : Money.Currency.t)
          ~got:(t.sell : Money.Amount.t)]
  else if not (Money.Amount.is_positive t.sell)
  then
    Or_error.error_s [%message "conversion sells nothing" ~sell:(t.sell : Money.Amount.t)]
  else Ok ()
;;
