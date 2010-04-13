module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class NetbillingGateway < Gateway
      URL = 'https://secure.netbilling.com:1402/gw/sas/direct3.1'
      
      TRANSACTIONS = {
        :authorization       => 'A',
        :purchase            => 'S',
        :referenced_credit   => 'R',
        :unreferenced_credit => 'C',
        :capture             => 'D'
      }
      
      SUCCESS_CODES = [ '1', 'T' ]
      SUCCESS_MESSAGE = 'The transaction was approved'
      FAILURE_MESSAGE = 'The transaction failed'
      TEST_LOGIN = '104901072025'

      self.display_name = 'NETbilling'
      self.homepage_url = 'http://www.netbilling.com'
      self.supported_countries = ['US']
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :jcb, :diners_club]
      
      def initialize(options = {})
        requires!(options, :login)
        @options = options
        super
      end  
      
      # Pass :store => true in the options to store the 
      # payment info at Netbilling. Store the transaction
      # number and last 5 digits of the credit card number
      # in your application's database. 
      # Pass a string into credit_card in the form:
      # "CS:121212121212:55555" where 121212121212 is the
      # transaction id and 55555 is the last 5 of the credit
      # card number to perform a repeat transaction.
      # Pass :store => true with a repeat transaction to
      # update the user's personal info, and use the new
      # transaction number and last 5 of the credit card
      # for future transactions using the updated info.
      
      def authorize(money, credit_card, options = {})
        post = {}
        add_amount(post, money)
        add_invoice(post, options)
        add_payment_source(post, credit_card, options)
        unless credit_card.is_a?(String) && !options[:store]
          add_address(post, credit_card, options)
          add_customer_data(post, options)
        end
        
        commit(:authorization, money, post)
      end
      
      def purchase(money, credit_card, options = {})
        post = {}
        add_amount(post, money)
        add_invoice(post, options)
        add_payment_source(post, credit_card, options)        
        unless credit_card.is_a?(String) && !options[:store]
          add_address(post, credit_card, options)
          add_customer_data(post, options)
        end
        
        commit(:purchase, money, post)
      end                       
    
      def capture(money, authorization, options = {})
        post = {}
        add_reference(post, authorization)
        commit(:capture, money, post)
      end
      
      def test?
        @options[:login] == TEST_LOGIN || super
      end
     
      private      
      def add_amount(post, money)
        post[:amount] = amount(money)
      end
      
      def add_reference(post, reference)
        post[:orig_id] = reference
      end
      
      def add_customer_data(post, options)
        post[:cust_email] = options[:email]
        post[:cust_ip] = options[:ip]
      end

      def add_address(post, credit_card, options)
        if billing_address = options[:billing_address] || options[:address]
          post[:bill_street]     = billing_address[:address1]
          post[:cust_phone]      = billing_address[:phone]
          post[:bill_zip]        = billing_address[:zip]
          post[:bill_city]       = billing_address[:city]
          post[:bill_country]    = billing_address[:country]
          post[:bill_state]      = billing_address[:state]
        end
        
       if shipping_address = options[:shipping_address]
         first_name, last_name = parse_first_and_last_name(shipping_address[:name])
        
         post[:ship_name1]      = first_name
         post[:ship_name2]      = last_name
         post[:ship_street]     = shipping_address[:address1]
         post[:ship_zip]        = shipping_address[:zip]
         post[:ship_city]       = shipping_address[:city]
         post[:ship_country]    = shipping_address[:country]
         post[:ship_state]      = shipping_address[:state]
       end
      end
    
      def add_invoice(post, options)
        post[:description] = options[:description]
      end
      
      def add_credit_card(post, credit_card, options={})
        post[:bill_name1] = credit_card.first_name
        post[:bill_name2] = credit_card.last_name
        post[:card_number] = credit_card.number
        post[:card_expire] = expdate(credit_card)
        post[:card_cvv2] = credit_card.verification_value
        post[:cisp_storage] = 1 if options[:store]
      end
      
      def add_cisp_id(post, cisp_id, options={})
        post[:card_number] = cisp_id
      end
      
      def parse(body)
        results = {}
        body.split(/&/).each do |pair|
          key,val = pair.split(/=/)
          results[key.to_sym] = CGI.unescape(val)
        end
        results
      end     
      
      def commit(action, money, parameters)
        response = parse(ssl_post(URL, post_data(action, parameters)))
        
        Response.new(success?(response), message_from(response), response, 
          :test => test_response?(response), 
          :authorization => response[:trans_id],
          :avs_result => { :code => response[:avs_code]},
          :cvv_result => response[:cvv2_code]
        )
      end
      
      def test_response?(response)
        !!(test? || response[:auth_msg] =~ /TEST/)
      end
      
      def success?(response)
        SUCCESS_CODES.include?(response[:status_code])
      end

      def message_from(response)
        success?(response) ? SUCCESS_MESSAGE : (response[:auth_msg] || FAILURE_MESSAGE)
      end
      
      def expdate(credit_card)
        year  = sprintf("%.4i", credit_card.year)
        month = sprintf("%.2i", credit_card.month)

        "#{month}#{year[-2..-1]}"
      end
      
      def post_data(action, parameters = {})
        parameters[:account_id] = @options[:login]
        parameters[:site_tag] = @options[:site_tag]
        parameters[:pay_type] = 'C'
        parameters[:tran_type] = TRANSACTIONS[action]  
        
        parameters.reject{|k,v| v.blank?}.collect { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }.join("&")
      end
      
      def parse_first_and_last_name(value)
        name = value.to_s.split(' ')
        
        last_name = name.pop || ''
        first_name = name.join(' ')
        [ first_name, last_name ] 
      end
      
      def add_payment_source(params, source, options={})
        case determine_funding_source(source)
        when :cisp_storage  then add_cisp_id(params, source, options)
        when :credit_card   then add_credit_card(params, source, options)
        end
      end
      
      def determine_funding_source(source)
        case 
        when source.is_a?(String) then :cisp_storage
        when CreditCard.card_companies.keys.include?(card_brand(source)) then :credit_card
        else raise ArgumentError, "Unsupported funding source provided"
        end
      end
    end
  end
end

