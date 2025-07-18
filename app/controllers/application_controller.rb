class ApplicationController < ActionController::Base
  include ActiveStorage::SetCurrent
  include Pundit::Authorization
  protect_from_forgery with: :exception, prepend: true
  rescue_from ActionController::InvalidAuthenticityToken, with: :display_auth_error

  rescue_from Pundit::NotAuthorizedError do
    admin_only_access_denied
  end

  # sets admin user for pundit policies
  def pundit_user
    current_admin
  end

  rescue_from ActionController::UnknownFormat, with: :raise_not_found
  rescue_from Elastic::Transport::Transport::Errors::ServiceUnavailable do
    # Non-standard code to distinguish Elasticsearch errors from standard 503s.
    # We can't use 444 because nginx will close connections without sending
    # response headers.
    head 445
  end

  def raise_not_found
    redirect_to '/404'
  end

  rescue_from Rack::Timeout::RequestTimeoutException, with: :raise_timeout
  
  def raise_timeout
    redirect_to timeout_error_path
  end

  helper :all # include all helpers, all the time

  include HtmlCleaner
  before_action :sanitize_ac_params

  # sanitize_params works best with a hash, and will convert
  # ActionController::Parameters to a hash in order to work with them anyway.
  #
  # Controllers need to deal with ActionController::Parameters, not hashes.
  # These methods hand the params as a hash to sanitize_params, and then
  # transforms the results back into ActionController::Parameters.
  def sanitize_ac_params
    sanitize_params(params.to_unsafe_h).each do |key, value|
      params[key] = transform_sanitized_hash_to_ac_params(key, value)
    end
  end

  include Pagy::Backend
  def pagy(collection, **vars)
    pagy_overflow_handler do
      super
    end
  end

  def pagy_query_result(query_result, **vars)
    pagy_overflow_handler do
      Pagy.new(
        count: query_result.total_entries,
        page: query_result.current_page,
        limit: query_result.per_page,
        **vars
      )
    end
  end

  def pagy_overflow_handler(*)
    yield
  rescue Pagy::OverflowError
    nil
  end

  def display_auth_error
    respond_to do |format|
      format.html do
        redirect_to auth_error_path
      end
      format.any(:js, :json) do
        render json: {
          errors: {
            auth_error: "Your current session has expired and we can't authenticate your request. Try logging in again, refreshing the page, or <a href='http://kb.iu.edu/data/ahic.html'>clearing your cache</a> if you continue to experience problems.".html_safe
          }
        }, status: :unprocessable_entity
      end
    end
  end

  def transform_sanitized_hash_to_ac_params(key, value)
    if value.is_a?(Hash)
      ActionController::Parameters.new(value)
    elsif value.is_a?(Array)
      value.map.with_index do |val, index|
        value[index] = transform_sanitized_hash_to_ac_params(key,  val)
      end
    else
      value
    end
  end

  helper_method :current_user
  helper_method :current_admin
  helper_method :logged_in?
  helper_method :logged_in_as_admin?
  helper_method :guest?

  # Title helpers
  helper_method :process_title

  # clear out the flash-being-set
  before_action :clear_flash_cookie
  def clear_flash_cookie
    cookies.delete(:flash_is_set)
  end

  after_action :check_for_flash
  def check_for_flash
    cookies[:flash_is_set] = 1 unless flash.empty?
  end

  # Override redirect_to so that if it's called in a before_action hook, it'll
  # still call check_for_flash after it runs.
  def redirect_to(*args, **kwargs)
    super.tap do
      check_for_flash
    end
  end

  after_action :ensure_admin_credentials
  def ensure_admin_credentials
    if logged_in_as_admin?
      # if we are logged in as an admin and we don't have the admin_credentials
      # set then set that cookie
      cookies[:admin_credentials] = { value: 1, expires: 1.year.from_now } unless cookies[:admin_credentials]
    else
      # if we are NOT logged in as an admin and we have the admin_credentials
      # set then delete that cookie
      cookies.delete :admin_credentials unless cookies[:admin_credentials].nil?
    end
  end

  # If there is no user_credentials cookie and the user appears to be logged in,
  # redirect to the lost cookie page. Needs to be before the code to fix
  # the user_credentials cookie or it won't fire.
  before_action :logout_if_not_user_credentials
  def logout_if_not_user_credentials
    if logged_in? && cookies[:user_credentials].nil? && controller_name != "sessions"
      logger.error "Forcing logout"
      sign_out
      redirect_to '/lost_cookie' and return
    end
  end

  # The user_credentials cookie is used by nginx to figure out whether or not
  # to cache the page, so we want to make sure that it's set when the user is
  # logged in, and cleared when the user is logged out.
  after_action :ensure_user_credentials
  def ensure_user_credentials
    if logged_in?
      cookies[:user_credentials] = { value: 1, expires: 1.year.from_now } unless cookies[:user_credentials]
    else
      cookies.delete :user_credentials unless cookies[:user_credentials].nil?
    end
  end

protected

  def logged_in?
    user_signed_in?
  end

  def logged_in_as_admin?
    admin_signed_in?
  end

  def guest?
    !(logged_in? || logged_in_as_admin?)
  end

  def process_title(string)
  	string = string.humanize.titleize

  	string = string.sub("Faq", "FAQ")
  	string = string.sub("Tos", "TOS")
  	string = string.sub("Dmca", "DMCA")
  	return string
  end

public

  before_action :load_admin_banner
  def load_admin_banner
    if Rails.env.development?
      @admin_banner = AdminBanner.where(active: true).last
    else
      # http://stackoverflow.com/questions/12891790/will-returning-a-nil-value-from-a-block-passed-to-rails-cache-fetch-clear-it
      # Basically we need to store a nil separately.
      @admin_banner = Rails.cache.fetch("admin_banner") do
        banner = AdminBanner.where(active: true).last
        banner.nil? ? "" : banner
      end
      @admin_banner = nil if @admin_banner == ""
    end
  end

  before_action :load_tos_popup
  def load_tos_popup
    # Integers only, YYYY-MM-DD format of date Board approved TOS
    @current_tos_version = 2024_11_19 # rubocop:disable Style/NumericLiterals
  end

  # store previous page in session to make redirecting back possible
  # if already redirected once, don't redirect again.
  before_action :store_location
  def store_location
    if session[:return_to] == "redirected"
      session.delete(:return_to)
    elsif request.fullpath.length > 200
      # Sessions are stored in cookies, which has a 4KB size limit.
      # Don't store paths that are too long (e.g. filters with lots of exclusions).
      # Also remove the previous stored path.
      session.delete(:return_to)
    else
      session[:return_to] = request.fullpath
    end
  end

  # Redirect to the URI stored by the most recent store_location call or
  # to the passed default.
  def redirect_back_or_default(default = root_path)
    back = session[:return_to]
    session.delete(:return_to)
    if back
      session[:return_to] = "redirected"
      redirect_to(back) and return
    else
      redirect_to(default) and return
    end
  end

  def after_sign_in_path_for(resource)
    if resource.is_a?(Admin)
      admins_path
    else
      back = session[:return_to]
      session.delete(:return_to)

      back || user_path(current_user)
    end
  end

  def authenticate_admin!
    if admin_signed_in?
      super
    else
      redirect_to root_path, notice: "I'm sorry, only an admin can look at that area"
      ## if you want render 404 page
      ## render file: File.join(Rails.root, 'public/404'), formats: [:html], status: 404, layout: false
    end
  end

  # Filter method - keeps users out of admin areas
  def admin_only
    authenticate_admin! || admin_only_access_denied
  end

  # Filter method to prevent admin users from accessing certain actions
  def users_only
    logged_in? || access_denied
  end

  # Filter method - requires user to have opendoors privs
  def opendoors_only
    (logged_in? && permit?("opendoors")) || access_denied
  end

  # Redirect as appropriate when an access request fails.
  #
  # The default action is to redirect to the login screen.
  #
  # Override this method in your controllers if you want to have special
  # behavior in case the user is not authorized
  # to access the requested action.  For example, a popup window might
  # simply close itself.
  def access_denied(options ={})
    store_location
    if logged_in?
      destination = options[:redirect].blank? ? user_path(current_user) : options[:redirect]
      # i18n-tasks-use t('users.reconfirm_email.access_denied.logged_in')
      flash[:error] = t(".access_denied.logged_in", default: t("application.access_denied.access_denied.logged_in")) # rubocop:disable I18n/DefaultTranslation
      redirect_to destination
    else
      destination = options[:redirect].blank? ? new_user_session_path : options[:redirect]
      flash[:error] = ts "Sorry, you don't have permission to access the page you were trying to reach. Please log in."
      redirect_to destination
    end
    false
  end

  def admin_only_access_denied
    respond_to do |format|
      format.html do
        flash[:error] = t("admin.access.page_access_denied") 
        redirect_to root_path
      end
      format.json do
        errors = [t("admin.access.action_access_denied")]
        render json: { errors: errors }, status: :forbidden
      end
      format.js do
        flash[:error] = t("admin.access.page_access_denied") 
        render js: "window.location.href = '#{root_path}';" 
      end
    end
  end

  # Filter method - prevents users from logging in as admin
  def user_logout_required
    if logged_in?
      flash[:notice] = 'Please log out of your user account first!'
      redirect_to root_path
    end
  end

  # Prevents admin from logging in as users
  def admin_logout_required
    if logged_in_as_admin?
      flash[:notice] = 'Please log out of your admin account first!'
      redirect_to root_path
    end
  end

  # Hide admin banner via cookies
  before_action :hide_banner
  def hide_banner
    if params[:hide_banner]
      session[:hide_banner] = true
    end
  end

  # Store the current user as a class variable in the User class,
  # so other models can access it with "User.current_user"
  around_action :set_current_user
  def set_current_user
    User.current_user = logged_in_as_admin? ? current_admin : current_user
    @current_user = current_user
    unless current_user.nil?
      @current_user_subscriptions_count, @current_user_visible_work_count, @current_user_bookmarks_count, @current_user_owned_collections_count, @current_user_challenge_signups_count, @current_user_offer_assignments, @current_user_unposted_works_size=
             Rails.cache.fetch("user_menu_counts_#{current_user.id}",
                               expires_in: 2.hours,
                               race_condition_ttl: 5) { "#{current_user.subscriptions.count}, #{current_user.visible_work_count}, #{current_user.bookmarks.count}, #{current_user.owned_collections.count}, #{current_user.challenge_signups.count}, #{current_user.offer_assignments.undefaulted.count + current_user.pinch_hit_assignments.undefaulted.count}, #{current_user.unposted_works.size}" }.split(",").map(&:to_i)
    end

    yield

    User.current_user = nil
    @current_user = nil
  end

  def load_collection
    @collection = Collection.find_by(name: params[:collection_id]) if params[:collection_id]
  end

  def collection_maintainers_only
    logged_in? && @collection && @collection.user_is_maintainer?(current_user) || access_denied
  end

  def collection_owners_only
    logged_in? && @collection && @collection.user_is_owner?(current_user) || access_denied
  end

  def not_allowed(fallback=nil)
    flash[:error] = ts("Sorry, you're not allowed to do that.")
    redirect_to (fallback || root_path) rescue redirect_to '/'
  end


  def get_page_title(fandom, author, title, options = {})
    # truncate any piece that is over 15 chars long to the nearest word
    if options[:truncate]
      fandom = fandom.gsub(/^(.{15}[\w.]*)(.*)/) {$2.empty? ? $1 : $1 + '...'}
      author = author.gsub(/^(.{15}[\w.]*)(.*)/) {$2.empty? ? $1 : $1 + '...'}
      title = title.gsub(/^(.{15}[\w.]*)(.*)/) {$2.empty? ? $1 : $1 + '...'}
    end

    @page_title = ""
    if logged_in? && !current_user.preference.try(:work_title_format).blank?
      @page_title = current_user.preference.work_title_format.dup
      @page_title.gsub!(/FANDOM/, fandom)
      @page_title.gsub!(/AUTHOR/, author)
      @page_title.gsub!(/TITLE/, title)
    else
      @page_title = title + " - " + author + " - " + fandom
    end

    @page_title += " [#{ArchiveConfig.APP_NAME}]" unless options[:omit_archive_name]
    @page_title.html_safe
  end

  public

  #### -- AUTHORIZATION -- ####

  # It is just much easier to do this here than to try to stuff variable values into a constant in environment.rb

  def is_registered_user?
    logged_in? || logged_in_as_admin?
  end

  def is_admin?
    logged_in_as_admin?
  end

  def see_adult?
    params[:anchor] = "comments" if (params[:show_comments] && params[:anchor].blank?)
    return true if cookies[:view_adult] || logged_in_as_admin?
    return false unless current_user
    return true if current_user.is_author_of?(@work)
    return true if current_user.preference && current_user.preference.adult
    return false
  end

  def use_caching?
    %w(staging production test).include?(Rails.env) && AdminSetting.current.enable_test_caching?
  end

  protected

  # Prevents banned and suspended users from adding/editing content
  def check_user_status
    if current_user.is_a?(User) && (current_user.suspended? || current_user.banned?)
      if current_user.suspended?
        suspension_end = current_user.suspended_until

        # Unban threshold is 6:51pm, 12 hours after the unsuspend_users rake task located in schedule.rb is run at 6:51am
        unban_theshold = DateTime.new(suspension_end.year, suspension_end.month, suspension_end.day, 18, 51, 0, "+00:00") 

        # If the stated suspension end date is after the unban threshold we need to advance a day 
        suspension_end = suspension_end.next_day(1) if suspension_end > unban_theshold
        localized_suspension_end = view_context.date_in_zone(suspension_end)
        flash[:error] = t("users.status.suspension_notice_html", suspended_until: localized_suspension_end, contact_abuse_link: view_context.link_to(t("users.contact_abuse"), new_abuse_report_path))
        
      else
        flash[:error] = t("users.status.ban_notice_html", contact_abuse_link: view_context.link_to(t("users.contact_abuse"), new_abuse_report_path))
      end
      redirect_to current_user
    end
  end

  # Prevents temporarily suspended users from deleting content
  def check_user_not_suspended
    return unless current_user.is_a?(User) && current_user.suspended?

    suspension_end = current_user.suspended_until

    # Unban threshold is 6:51pm, 12 hours after the unsuspend_users rake task located in schedule.rb is run at 6:51am
    unban_theshold = DateTime.new(suspension_end.year, suspension_end.month, suspension_end.day, 18, 51, 0, "+00:00") 

    # If the stated suspension end date is after the unban threshold we need to advance a day 
    suspension_end = suspension_end.next_day(1) if suspension_end > unban_theshold
    localized_suspension_end = view_context.date_in_zone(suspension_end)
    
    flash[:error] = t("users.status.suspension_notice_html", suspended_until: localized_suspension_end, contact_abuse_link: view_context.link_to(t("users.contact_abuse"), new_abuse_report_path))

    redirect_to current_user
  end

  # Does the current user own a specific object?
  def current_user_owns?(item)
  	!item.nil? && current_user.is_a?(User) && (item.is_a?(User) ? current_user == item : current_user.is_author_of?(item))
  end

  # Make sure a specific object belongs to the current user and that they have permission
  # to view, edit or delete it
  def check_ownership
  	access_denied(redirect: @check_ownership_of) unless current_user_owns?(@check_ownership_of)
  end
  def check_ownership_or_admin
     return true if logged_in_as_admin?
     access_denied(redirect: @check_ownership_of) unless current_user_owns?(@check_ownership_of)
  end

  # Make sure the user is allowed to see a specific page
  # includes a special case for restricted works and series, since we want to encourage people to sign up to read them
  def check_visibility
    if @check_visibility_of.respond_to?(:restricted) && @check_visibility_of.restricted && User.current_user.nil?
      redirect_to new_user_session_path(restricted: true)
    elsif @check_visibility_of.is_a? Skin
      access_denied unless logged_in_as_admin? || current_user_owns?(@check_visibility_of) || @check_visibility_of.official?
    else
      is_hidden = (@check_visibility_of.respond_to?(:visible) && !@check_visibility_of.visible) ||
                  (@check_visibility_of.respond_to?(:visible?) && !@check_visibility_of.visible?) ||
                  (@check_visibility_of.respond_to?(:hidden_by_admin?) && @check_visibility_of.hidden_by_admin?)
      can_view_hidden = logged_in_as_admin? || current_user_owns?(@check_visibility_of)
      access_denied if (is_hidden && !can_view_hidden)
    end
  end

  # Make sure user is allowed to access tag wrangling pages
  def check_permission_to_wrangle
    if AdminSetting.current.tag_wrangling_off? && !logged_in_as_admin?
      flash[:error] = "Wrangling is disabled at the moment. Please check back later."
      redirect_to root_path
    else
      logged_in_as_admin? || permit?("tag_wrangler") || access_denied
    end
  end

  # Checks if user is allowed to see related page if parent item is hidden or in unrevealed collection
  # Checks if user is logged in if parent item is restricted
  def check_visibility_for(parent)
    return if logged_in_as_admin? || current_user_owns?(parent) # Admins and the owner can see all related pages

    access_denied(redirect: root_path) if parent.try(:hidden_by_admin) || parent.try(:in_unrevealed_collection) || (parent.respond_to?(:visible?) && !parent.visible?)
  end

  public

  def valid_sort_column(param, model='work')
    allowed = []
    if model.to_s.downcase == 'work'
      allowed = %w(author title date created_at word_count hit_count)
    elsif model.to_s.downcase == 'tag'
      allowed = %w[name created_at taggings_count_cache uses]
    elsif model.to_s.downcase == 'collection'
      allowed = %w(collections.title collections.created_at)
    elsif model.to_s.downcase == 'prompt'
      allowed = %w(fandom created_at prompter)
    elsif model.to_s.downcase == 'claim'
      allowed = %w(created_at claimer)
    end
    !param.blank? && allowed.include?(param.to_s.downcase)
  end

  def set_sort_order
    # sorting
    @sort_column = (valid_sort_column(params[:sort_column],"prompt") ? params[:sort_column] : 'id')
    @sort_direction = (valid_sort_direction(params[:sort_direction]) ? params[:sort_direction] : 'DESC')
    if !params[:sort_direction].blank? && !valid_sort_direction(params[:sort_direction])
      params[:sort_direction] = 'DESC'
    end
    @sort_order = @sort_column + " " + @sort_direction
  end

  def valid_sort_direction(param)
    !param.blank? && %w(asc desc).include?(param.to_s.downcase)
  end

  def flash_search_warnings(result)
    if result.respond_to?(:error) && result.error
      flash.now[:error] = result.error
    elsif result.respond_to?(:notice) && result.notice
      flash.now[:notice] = result.notice
    end
  end

  # Don't get unnecessary data for json requests

  skip_before_action  :load_admin_banner,
                      :store_location,
                      if: proc { %w(js json).include?(request.format) }

end
