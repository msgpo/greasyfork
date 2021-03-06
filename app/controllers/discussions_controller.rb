require 'discussion_converter'

class DiscussionsController < ApplicationController
  include DiscussionHelper
  include ScriptAndVersions

  before_action :authenticate_user!, only: [:new, :create, :subscribe, :unsubscribe]
  before_action :moderators_only, only: :destroy
  before_action :greasy_only, only: :new

  layout 'discussions', only: :index
  layout 'application', only: [:new, :create]

  def index
    @discussions = Discussion
                   .includes(:poster, :script, :discussion_category)
                   .order(stat_last_reply_date: :desc)
    case script_subset
    when :sleazyfork
      @discussions = @discussions.where(scripts: { sensitive: true })
    when :greasyfork
      @discussions = @discussions.where.not(scripts: { sensitive: true })
    when :all
      # No restrictions
    else
      raise "Unknown subset #{script_subset}"
    end

    if params[:category]
      if params[:category] == 'no-scripts'
        @category = params[:category]
        @discussions = @discussions.where(discussion_category: DiscussionCategory.non_script)
      else
        @category = DiscussionCategory.find_by(category_key: params[:category])
        @discussions = @discussions.where(discussion_category: @category) if @category
      end
    end

    if current_user
      case params[:me]
      when 'started'
        @discussions = @discussions.where(poster: current_user)
      when 'comment'
        @discussions = @discussions.with_comment_by(current_user)
      when 'script'
        @discussions = @discussions.where(script_id: current_user.script_ids)
      when 'subscribed'
        @discussions = @discussions.where(id: current_user.discussion_subscriptions.pluck(:discussion_id))
      end
    end

    if params[:user].to_i > 0
      @by_user = User.find_by(id: params[:user].to_i)
      @discussions = @discussions.with_comment_by(@by_user) if @by_user
    end

    @discussions = @discussions.paginate(page: params[:page], per_page: 25)

    @discussion_ids_read = DiscussionRead.read_ids_for(@discussions, current_user) if current_user
  end

  def show
    @discussion = discussion_scope.find(params[:id])

    if @discussion.script
      return if handle_publicly_deleted(@discussion.script)

      case script_subset
      when :sleazyfork
        unless @discussion.script.sensitive?
          render_404
          return
        end
      when :greasyfork
        if @discussion.script.sensitive?
          render_404
          return
        end
      when :all
        # No restrictions
      else
        raise "Unknown subset #{script_subset}"
      end
    end

    @comment = @discussion.comments.build(text_markup: current_user&.preferred_markup)
    @subscribe = current_user&.subscribed_to?(@discussion)

    record_view(@discussion) if current_user

    render layout: @script ? 'scripts' : 'application'
  end

  def new
    @discussion = Discussion.new(poster: current_user)
    @discussion.comments.build(poster: current_user)
    @subscribe = true
  end

  def create
    @discussion = discussion_scope.new(discussion_params)
    @discussion.poster = @discussion.comments.first.poster = current_user
    if @script
      @discussion.script = @script
      @discussion.discussion_category = DiscussionCategory.script_discussions
    end
    @discussion.comments.first.first_comment = true
    @subscribe = params[:subscribe] == '1'

    recaptcha_ok = current_user.needs_to_recaptcha? ? verify_recaptcha : true
    unless recaptcha_ok && @discussion.valid?
      render :new
      return
    end

    @discussion.save!
    @discussion.comments.first.send_notifications!

    DiscussionSubscription.find_or_create_by!(user: current_user, discussion: @discussion) if @subscribe

    redirect_to @discussion.path
  end

  def destroy
    discussion = discussion_scope.find(params[:id])
    discussion.destroy!
    if discussion.script
      redirect_to script_path(discussion.script)
    else
      redirect_to root_path
    end
  end

  def subscribe
    discussion = discussion_scope.find(params[:id])
    DiscussionSubscription.find_or_create_by!(user: current_user, discussion: discussion)
    respond_to do |format|
      format.js { head 200 }
      format.all { redirect_to discussion.path }
    end
  end

  def unsubscribe
    discussion = discussion_scope.find(params[:id])
    DiscussionSubscription.find_by(user: current_user, discussion: discussion)&.destroy
    respond_to do |format|
      format.js { head 200 }
      format.all { redirect_to discussion.path }
    end
  end

  def old_redirect
    redirect_to Discussion.find_by!(migrated_from: params[:id]).url, status: 301
  end

  private

  def discussion_scope
    if params[:script_id]
      @script = Script.find(params[:script_id])
      @script.discussions
    else
      Discussion
    end
  end

  def discussion_params
    params
      .require(:discussion)
      .permit(:rating, :title, :discussion_category_id, comments_attributes: [:text, :text_markup, attachments: []])
  end

  def record_view(discussion)
    DiscussionRead.upsert({ user_id: current_user.id, discussion_id: discussion.id, read_at: Time.now })
  end
end
