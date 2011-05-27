function apply_voc_exemplars(models)
%% Apply a set of models (raw exemplars, trained exemplars, dalals, etc) to a set of images.  Script can be ran in
%% parallel with no arguments.  
%% After running script, use grid=load_result_grid(models) to
%% load results
%
%% models:           input cell array of models (try models=load_all_models)

%% Tomasz Malisiewicz (tomasz@cmu.edu)

%we save results every NIMS_PER_CHUNK images
NIMS_PER_CHUNK = 10;

VOCinit;
curset = 'both';

%Store exemplars for this class
if ~exist('models','var')
  [cls,DET_TYPE] = load_default_class;
  models = load_all_models(cls,[DET_TYPE '-stripped']);
end

%Only allow display to be enabled on a machine with X
[v,r] = unix('hostname');
if strfind(r,VOCopts.display_machine)==1
  display = 1;
else
  display = 0;
end
display = 0;

if display == 1
  fprintf(1,'DISPLAY ENABLED, NOT SAVING RESULTS!\n');
end

localizeparams = get_default_mining_params;
if length(strfind(models{1}.models_name,'-ncc'))
  localizeparams.ADJUST_DISTANCES = 1;
end

%if strcmp(models{1}.models_name,'dalal')
%  localizeparams.TOPK = 100;
%  localizeparams.thresher = -2.5;
%end

fprintf(1,'Loading default set of images\n');
if display == 1
  %If display is enabled, we must be on a machine running X, thus
  %we apply results on in-class images from trainval
  curset = 'test';%'trainval';
  curcls = models{1}.cls;  
  %curcls = 'car';
  curcls = 'bus';
  %curcls = 'tvmonitor';
  
  bg = get_pascal_bg(curset,sprintf('%s',curcls));
  %even better yet, we apply on the images from where the models
  %came from
  %bg = cellfun2(@(x)sprintf(VOCopts.imgpath,x.curid),models);
else
  bg = cat(1,get_pascal_bg('trainval'),get_pascal_bg('test'));
  %bg = get_pascal_bg('trainval');
  fprintf(1,'bg length is %d\n',length(bg));
end

setname = [curset '.' models{1}.cls];
lrstring = '';

baser = sprintf('%s/applied/%s-%s/',VOCopts.localdir,setname, ...
                models{1}.models_name);

if ~exist(baser,'dir') && (display == 0)
  fprintf(1,'Making directory %s\n',baser);
  mkdir(baser);
end

%% Chunk the data into NIMS_PER_CHUNK images per chunk so that we
%process several images, then write results for entire chunk
inds = do_partition(1:length(bg),NIMS_PER_CHUNK);

% randomize chunk orderings
myRandomize;
ordering = randperm(length(inds));
if display == 1
  ordering = 1:length(ordering);
end

[v,host_string]=unix('hostname');

for i = 1:length(ordering)

  filer = sprintf('%s/result_%05d.mat',baser,ordering(i));
  filerlock = [filer '.lock'];

  if display == 0
    if fileexists(filer) || (mymkdir_dist(filerlock) == 0)
      continue
    end
  end
  
  res = cell(0,1);

  %% pre-load all images in a chunk
  fprintf(1,'Preloading %d images\n',length(inds{ordering(i)}));
  clear Is;
  for j = 1:length(inds{ordering(i)})
    Is{j} = convert_to_I(bg{inds{ordering(i)}(j)});
    %fprintf(1,'size .4 hack\n');
    %Is{j} = max(0.0,min(1.0,imresize(Is{j},.2)));
  end
  
  for j = 1:length(inds{ordering(i)})

    index = inds{ordering(i)}(j);
    fprintf(1,'   ---image %d\n',index);
    Iname = bg{index};
    I = Is{j};
       
    starter = tic;
    [rs,t] = localizemeHOG(I,models,localizeparams);
    scores = cat(2,rs.score_grid{:});
    [aa,bb] = max(scores);
    fprintf(1,' took %.3fsec, maxhit=%.3f, #hits=%d\n',...
            toc(starter),aa,length(scores));

    tic
    [coarse_boxes] = extract_bbs_from_rs(rs, index);
    toc
    
    boxes = coarse_boxes;
    %map GT boxes from training images onto test image
    boxes = adjust_boxes(coarse_boxes,models);
      

    if display == 1       
      %extract detection box vectors from the localization results

      
      if size(boxes,1)>=1
        boxes(:,5) = 1:size(boxes,1);
      end
      
      % if exist('betas','var')
      %   boxes = calibrate_boxes(boxes,betas);
      % end
      
      [aa,bb] = sort(boxes(:,end),'descend');
      boxes = boxes(bb,:);
 
      %already nmsed
      %boxes = nms_within_exemplars(boxes,.5);

      %% ONLY SHOW TOP 5 detections or fewer
      boxes = boxes(1:min(size(boxes,1),8),:);
      
      if size(boxes,1) >=1
        figure(1)
        clf
        % stuff.filer = '';

                    
        % exemplar_overlay = exemplar_inpaint(boxes(1,:), ...
        %                                     models{boxes(1,6)}, ...
        %                                     stuff);

        % show_hits_figure_iccv(models,boxes,I,I,exemplar_overlay,I);
        
        show_hits_figure(models, boxes, I);
        drawnow

        pause
      else
        fprintf(1,'No detections in this Image\n');
      end
    end
        

    extras = [];
    res{j}.coarse_boxes = coarse_boxes;
    res{j}.bboxes = boxes;
    %dont save SVs
    %if isfield(rs,'support_grid')
    %  rs = rmfield(rs,'support_grid');
    %end
    %res{j}.rs = rs;
    res{j}.index = index;
    res{j}.extras = extras;
    res{j}.imbb = [1 1 size(I,2) size(I,1)];
    
    Iname = bg{index};
    [tmp,curid,tmp] = fileparts(Iname);
    res{j}.curid = curid;
    
    try
      % get GT objects for this image
      recs = PASreadrecord(sprintf(VOCopts.annopath,curid));

      % get overlaps with all ground-truths (makes sense for VOC
      % images only)
      gtbb = cat(1,recs.objects.bbox);
      extras.os = getosmatrix_bb(boxes,gtbb);
      extras.cats = {recs.objects.class};
      res{j}.extras = extras;
    catch
    end
    
  end

  % save results into file and remove lock file
  if display == 0
    save(filer,'res');
    try
      rmdir(filerlock);
    catch
      fprintf(1,'Directory %s already gone\n',filerlock);
    end
  end  
end
